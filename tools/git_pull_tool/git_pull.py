#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""git_pull.py - 自动拉取多个 Git 仓库的最新分支代码（Python 3.8+）"""

import argparse
import json
import logging
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_CONFIG = "config.json"
DEFAULT_CONCURRENCY = 5
DEFAULT_REMOTE = "origin"
DEFAULT_BRANCH_PATTERN = r"^feature_(\d{2})(\d{2})_([A-Z])"

LOG_DIR = Path("logs")

CONFLICT_KEYWORDS = [
    "CONFLICT",
    "Automatic merge failed",
    "would be overwritten by checkout",
    "Your local changes would be overwritten",
    "you need to resolve your current index first",
]


def run_git(repo_path: Path, args: List[str], check: bool = False) -> Tuple[int, str, str]:
    """在指定仓库目录下执行 git 命令，返回 (returncode, stdout, stderr)。"""
    cmd = ["git", "-C", str(repo_path)] + args
    logging.debug("执行: %s", " ".join(cmd))
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if check and proc.returncode != 0:
        raise subprocess.CalledProcessError(
            proc.returncode, cmd, output=proc.stdout, stderr=proc.stderr
        )
    return proc.returncode, proc.stdout, proc.stderr


def is_git_repo(repo_path: Path) -> bool:
    """判断路径是否为有效的 Git 仓库。"""
    if not repo_path.exists():
        return False
    rc, _, _ = run_git(repo_path, ["rev-parse", "--git-dir"])
    return rc == 0


def list_remote_branches(repo_path: Path, remote: str) -> List[str]:
    """列出指定 remote 下的远程分支名（不含 remote 前缀）。"""
    rc, out, _ = run_git(
        repo_path,
        ["for-each-ref", "--format=%(refname:short)", f"refs/remotes/{remote}"],
    )
    if rc != 0:
        return []

    branches: List[str] = []
    prefix = remote + "/"
    for line in out.splitlines():
        line = line.strip()
        if not line or line == f"{remote}/HEAD":
            continue
        if line.startswith(prefix):
            branches.append(line[len(prefix):])
    return branches


def find_latest_branch(
    repo_path: Path, remote: str, pattern: re.Pattern, dry_run: bool
) -> Optional[str]:
    """在未配置分支时，从远程分支中按规则找出最新的一个。"""
    if not dry_run:
        # 先尝试 fetch，失败也继续用已有远程分支信息做判断
        run_git(repo_path, ["fetch", remote], check=False)

    branches = list_remote_branches(repo_path, remote)
    groups: Dict[str, List[str]] = {}
    best_key: Optional[Tuple[int, int]] = None

    for branch in branches:
        match = pattern.match(branch)
        if not match:
            continue
        base = match.group(0)
        year = int(match.group(1))
        month = int(match.group(2))
        suffix = match.group(3)
        # 年月越大越新；同年月下字母越大越新
        key = (year * 100 + month, ord(suffix))

        if best_key is None or key > best_key:
            best_key = key
            groups = {base: [branch]}
        elif key == best_key:
            groups.setdefault(base, []).append(branch)

    if not groups or best_key is None:
        return None

    # 同一基础分支名（如 feature_2609_A）可能有多个变体（如 feature_2609_A_gray）
    base = list(groups.keys())[0]
    candidates = groups[base]
    if base in candidates:
        return base
    return candidates[0]


def classify_failure(
    returncode: int, stdout: str, stderr: str, default_msg: str
) -> Tuple[str, str]:
    """根据 git 输出判断是代码冲突还是其他错误。"""
    combined = (stdout + "\n" + stderr).lower()
    if any(kw.lower() in combined for kw in CONFLICT_KEYWORDS):
        return "conflict", default_msg + "（发生冲突，请手动解决）"
    detail = (stderr.strip() or stdout.strip()).replace("\n", " ")
    return "error", f"{default_msg}: {detail}"


def checkout_and_pull(
    repo_path: Path, remote: str, branch: str
) -> Tuple[str, str]:
    """切换到目标分支并拉取最新代码。返回 (status, message)。"""
    rc, out, _ = run_git(repo_path, ["branch", "--list", branch])
    local_exists = bool(out.strip())

    if local_exists:
        rc, out, err = run_git(repo_path, ["checkout", branch])
        if rc != 0:
            return classify_failure(rc, out, err, f"切换到分支 {branch} 失败")
    else:
        rc, out, err = run_git(repo_path, ["checkout", "-b", branch, f"{remote}/{branch}"])
        if rc != 0:
            return classify_failure(rc, out, err, f"创建并切换到分支 {branch} 失败")

    rc, out, err = run_git(repo_path, ["pull", "--no-rebase", remote, branch])
    if rc != 0:
        return classify_failure(rc, out, err, f"拉取 {remote}/{branch} 失败")

    return "success", f"成功切换到 {branch} 并拉取最新代码"


def process_repo(
    repo_config: Dict[str, Any],
    gerrit_config: Optional[Dict[str, Any]],
    dry_run: bool,
) -> Dict[str, Any]:
    """处理单个仓库。返回结果字典。"""
    repo_path = Path(repo_config["path"])
    remote = repo_config["remote"]
    configured_branch = repo_config.get("branch")
    pattern = re.compile(repo_config["branch_pattern"])

    result: Dict[str, Any] = {
        "path": str(repo_path),
        "target_branch": configured_branch,
        "status": "pending",
        "message": "",
    }

    if not repo_path.exists():
        if gerrit_config and gerrit_config.get("enabled"):
            clone_root = gerrit_config.get("clone_root")
            if not clone_root:
                result["status"] = "error"
                result["message"] = "Gerrit 配置缺少 clone_root，无法推导工程名"
                return result

            project = derive_project_name(repo_path, Path(clone_root))
            if not project:
                result["status"] = "error"
                result[
                    "message"
                ] = f"仓库路径 {repo_path} 不在 clone_root {clone_root} 下，无法推导 Gerrit 工程名"
                return result

            clone_url = build_clone_url(project, gerrit_config)
            status, message = clone_repo(repo_path, clone_url, remote, dry_run)

            if dry_run:
                branch_hint = configured_branch or "最新分支"
                result["status"] = "skipped"
                result[
                    "message"
                ] = f"{message}，然后切换到 {branch_hint} 并执行 git pull"
                return result

            if status != "success":
                result["status"] = status
                result["message"] = message
                return result
        else:
            result["status"] = "error"
            result["message"] = "仓库路径不存在"
            return result

    if not is_git_repo(repo_path):
        result["status"] = "error"
        result["message"] = "不是有效的 Git 仓库"
        return result

    branch = configured_branch
    if not branch:
        latest = find_latest_branch(repo_path, remote, pattern, dry_run)
        if not latest:
            result["status"] = "error"
            result["message"] = "未找到符合规则的最新分支"
            return result
        branch = latest
        result["target_branch"] = branch

    if dry_run:
        result["status"] = "skipped"
        result["message"] = f"[模拟] 将切换到 {branch} 并执行 git pull"
        return result

    status, message = checkout_and_pull(repo_path, remote, branch)
    result["status"] = status
    result["message"] = message
    return result


def setup_logging(log_dir: Path) -> None:
    """配置日志：同时输出到控制台和日志文件。"""
    log_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = log_dir / f"git_pull_{timestamp}.log"

    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    fh = logging.FileHandler(log_file, encoding="utf-8")
    fh.setFormatter(formatter)
    logger.addHandler(fh)

    ch = logging.StreamHandler(sys.stdout)
    ch.setFormatter(formatter)
    logger.addHandler(ch)

    logging.info("日志文件: %s", log_file)


def build_default_config(repos: List[Dict[str, str]]) -> Dict[str, Any]:
    """生成默认配置字典。"""
    return {
        "concurrency": DEFAULT_CONCURRENCY,
        "remote": DEFAULT_REMOTE,
        "branch_pattern": DEFAULT_BRANCH_PATTERN,
        "gerrit": {
            "user": "",
            "host": "",
            "port": 29418,
            "clone_root": "",
            "enabled": False,
        },
        "repos": repos,
    }


def save_config(config: Dict[str, Any], output: Path, force: bool) -> None:
    """将配置写入 JSON 文件。"""
    if output.exists() and not force:
        raise FileExistsError(
            f"配置文件已存在: {output}，添加 --force 可覆盖"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        f.write("\n")


def init_from_txt(txt_path: Path, output: Path, force: bool) -> None:
    """从 txt 文件初始化配置。"""
    repos: List[Dict[str, str]] = []
    with txt_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            p = Path(line)
            repos.append({"path": p.as_posix()})

    config = build_default_config(repos)
    save_config(config, output, force)
    print(f"已从 {txt_path} 生成配置，共 {len(repos)} 个仓库: {output}")


def scan_repos(root: Path, output: Path, force: bool) -> None:
    """扫描目录下的 Git 仓库并生成配置。"""
    repos: List[Dict[str, str]] = []
    for dirpath, dirnames, _filenames in os.walk(root):
        if ".git" in dirnames:
            repo_dir = Path(dirpath).resolve()
            repos.append({"path": repo_dir.as_posix()})
            # 不再进入该仓库内部继续扫描
            dirnames.remove(".git")

    repos.sort(key=lambda x: x["path"])
    config = build_default_config(repos)
    save_config(config, output, force)
    print(f"已扫描 {root}，发现 {len(repos)} 个仓库，生成配置: {output}")


def load_gerrit_config(raw: Dict[str, Any], base_dir: Path) -> Optional[Dict[str, Any]]:
    """读取并校验 Gerrit SSH 克隆配置。"""
    gerrit_raw = raw.get("gerrit")
    if not gerrit_raw:
        return None
    if not isinstance(gerrit_raw, dict):
        raise ValueError("gerrit 配置必须是 JSON 对象")

    enabled = gerrit_raw.get("enabled", True)
    if not enabled:
        return {"enabled": False}

    required_fields = ["user", "host", "port", "clone_root"]
    missing = [field for field in required_fields if not gerrit_raw.get(field)]
    if missing:
        raise ValueError(
            f"gerrit 自动克隆已启用，但缺少字段: {', '.join(missing)}"
        )

    clone_root = Path(gerrit_raw["clone_root"])
    if not clone_root.is_absolute():
        clone_root = (base_dir / clone_root).resolve()

    return {
        "enabled": True,
        "user": gerrit_raw["user"],
        "host": gerrit_raw["host"],
        "port": int(gerrit_raw["port"]),
        "clone_root": str(clone_root),
    }


def derive_project_name(repo_path: Path, clone_root: Path) -> Optional[str]:
    """根据本地仓库路径和 clone_root 推导 Gerrit 工程名。"""
    try:
        rel = repo_path.resolve().relative_to(clone_root.resolve())
    except ValueError:
        return None
    project = rel.as_posix().strip("/")
    return project or None


def build_clone_url(project: str, gerrit: Dict[str, Any]) -> str:
    """构造 Gerrit SSH 克隆地址。"""
    project = project.strip("/")
    return f"ssh://{gerrit['user']}@{gerrit['host']}:{gerrit['port']}/{project}"


def clone_repo(
    repo_path: Path, clone_url: str, remote: str, dry_run: bool
) -> Tuple[str, str]:
    """通过 SSH 克隆仓库到指定路径。"""
    if dry_run:
        return "skipped", f"[模拟] 将克隆 {clone_url} 到 {repo_path}"

    repo_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["git", "clone"]
    if remote != DEFAULT_REMOTE:
        cmd.extend(["-o", remote])
    cmd.extend([clone_url, str(repo_path)])
    logging.debug("执行: %s", " ".join(cmd))

    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode != 0:
        detail = (proc.stderr.strip() or proc.stdout.strip()).replace("\n", " ")
        return "error", f"克隆失败: {detail}"
    return "success", f"已成功克隆到 {repo_path}"


def load_config(config_path: Path) -> Dict[str, Any]:
    """读取配置文件，并补齐默认值与绝对路径。"""
    with config_path.open("r", encoding="utf-8") as f:
        raw = json.load(f)

    base_dir = config_path.parent

    config: Dict[str, Any] = {
        "concurrency": raw.get("concurrency", DEFAULT_CONCURRENCY),
        "remote": raw.get("remote", DEFAULT_REMOTE),
        "branch_pattern": raw.get("branch_pattern", DEFAULT_BRANCH_PATTERN),
        "repos": [],
    }

    for item in raw.get("repos", []):
        if not isinstance(item, dict):
            continue
        path_str = item.get("path")
        if not path_str:
            continue
        p = Path(path_str)
        if not p.is_absolute():
            p = (base_dir / p).resolve()

        repo_conf: Dict[str, Any] = {
            "path": str(p),
            "branch": item.get("branch"),
            "remote": item.get("remote", config["remote"]),
            "branch_pattern": item.get("branch_pattern", config["branch_pattern"]),
        }
        config["repos"].append(repo_conf)

    config["gerrit"] = load_gerrit_config(raw, base_dir)
    return config


def pull_repos(config: Dict[str, Any], dry_run: bool) -> None:
    """并发拉取所有仓库。"""
    results: List[Dict[str, Any]] = []
    total = len(config["repos"])
    if total == 0:
        logging.warning("配置文件中没有仓库")
        return

    logging.info(
        "开始处理，共 %d 个仓库，并发数 %d，模拟运行=%s",
        total,
        config["concurrency"],
        dry_run,
    )

    with ThreadPoolExecutor(max_workers=config["concurrency"]) as executor:
        future_to_repo = {
            executor.submit(process_repo, repo, config.get("gerrit"), dry_run): repo
            for repo in config["repos"]
        }
        for future in as_completed(future_to_repo):
            result = future.result()
            results.append(result)

            status = result["status"]
            path = result["path"]
            target = result.get("target_branch") or ""
            msg = result["message"]

            if status == "success":
                logging.info("[成功] %s -> %s: %s", path, target, msg)
            elif status == "conflict":
                logging.warning("[冲突] %s -> %s: %s", path, target, msg)
            elif status == "error":
                logging.error("[失败] %s -> %s: %s", path, target, msg)
            else:
                logging.info("[%s] %s -> %s: %s", status.upper(), path, target, msg)

    success = sum(1 for r in results if r["status"] == "success")
    conflict = sum(1 for r in results if r["status"] == "conflict")
    error = sum(1 for r in results if r["status"] == "error")
    skipped = sum(1 for r in results if r["status"] == "skipped")

    summary = (
        f"汇总: 总数={total}, 成功={success}, 冲突={conflict}, "
        f"失败={error}, 跳过={skipped}"
    )
    logging.info(summary)
    print(f"\n{summary}")

    if conflict or error:
        print("\n失败/冲突仓库:")
        for r in results:
            if r["status"] in ("conflict", "error"):
                print(f"  - {r['path']}: {r['message']}")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="自动拉取多个 Git 仓库的最新分支代码（Python 3.8+）"
    )
    parser.add_argument(
        "--config",
        default=DEFAULT_CONFIG,
        help="配置文件路径（默认: config.json）",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="模拟运行，仅输出计划执行的步骤，不修改仓库",
    )
    parser.add_argument(
        "--init-txt",
        metavar="TXT",
        help="从 txt 文件初始化配置，每行一个仓库路径",
    )
    parser.add_argument(
        "--scan",
        metavar="DIR",
        help="扫描目录下的所有 Git 仓库并生成配置",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_CONFIG,
        help="生成配置时的输出路径（默认: config.json）",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="覆盖已存在的输出配置文件",
    )

    args = parser.parse_args(argv)

    try:
        if args.init_txt:
            init_from_txt(Path(args.init_txt), Path(args.output), args.force)
            return 0

        if args.scan:
            scan_repos(Path(args.scan), Path(args.output), args.force)
            return 0

        config_path = Path(args.config)
        if not config_path.exists():
            print(f"错误: 配置文件不存在: {config_path}", file=sys.stderr)
            return 1

        config = load_config(config_path)
        setup_logging(LOG_DIR)
        pull_repos(config, args.dry_run)
        return 0

    except Exception as exc:  # pylint: disable=broad-except
        print(f"错误: {exc}", file=sys.stderr)
        logging.exception("程序异常")
        return 1


if __name__ == "__main__":
    sys.exit(main())
