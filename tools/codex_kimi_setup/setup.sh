#!/usr/bin/env bash
#
# Codex Kimi 一键配置工具
# 仿 DeepSeek 官方 codex 配置脚本体验：
#   - 备份现有配置到 ~/.codex/backup-kimi/<时间戳>/
#   - 向 models.json 合并写入 k3 / k3-256k / kimi-for-coding 模型元数据（保留已有条目）
#   - 只修改 config.toml 必要字段，其余配置（plugins/mcp/projects 等）原样保留
#   - 写入前做 TOML/JSON 语法校验，失败自动从备份还原
#
# 说明：Codex 的 model_provider 是全局唯一的，请求只发往当前 provider 的 base_url，
# 模型目录里的条目不携带 provider 归属。因此跨家（Kimi <-> DeepSeek）切换必须整体
# 改 provider，不能只在界面里选另一家模型。
#
set -euo pipefail

VERSION="1.0.0"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_TOML="$CODEX_HOME/config.toml"
MODELS_JSON="$CODEX_HOME/models.json"
BACKUP_ROOT="$CODEX_HOME/backup-kimi"
KIMI_BASE_URL="https://api.kimi.com/coding/v1"

log() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

have_python3() { command -v python3 >/dev/null 2>&1; }
have_tomllib()  { have_python3 && python3 -c 'import tomllib' >/dev/null 2>&1; }

# 读取 config.toml 顶层简单字符串键的值（如 model / model_provider）
cfg_get() {
    grep -m1 -E "^$1[[:space:]]*=" "$CONFIG_TOML" 2>/dev/null \
        | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/' || true
}

mask() { # 只露前 7 后 4
    local s="$1"
    if [[ ${#s} -le 11 ]]; then
        printf '%s' "${s:0:3}****"
    else
        printf '%s****%s' "${s:0:7}" "${s: -4}"
    fi
}

# ---------------------------------------------------------------------------
# 备份 / 还原
# ---------------------------------------------------------------------------

backup_current() { # $1=动作说明；输出备份目录路径
    local reason="$1" ts dir
    ts="$(date +%Y%m%d_%H%M%S)"
    dir="$BACKUP_ROOT/$ts"
    while [[ -e "$dir" ]]; do dir="${dir}_1"; done
    mkdir -p "$dir"
    [[ -f "$CONFIG_TOML" ]] && cp "$CONFIG_TOML" "$dir/config.toml"
    [[ -f "$MODELS_JSON" ]] && cp "$MODELS_JSON" "$dir/models.json"
    {
        echo "script_version=$VERSION"
        echo "action=$reason"
        echo "installed_at=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "prev_model=$(cfg_get model)"
        echo "prev_model_provider=$(cfg_get model_provider)"
        echo "codex_home=$CODEX_HOME"
    } > "$dir/manifest.txt"
    printf '%s' "$dir"
}

restore_from() { # $1=备份目录；把该目录中的文件复制回 CODEX_HOME
    local dir="$1"
    [[ -d "$dir" ]] || die "备份目录不存在: $dir"
    [[ -f "$dir/config.toml" ]] && cp "$dir/config.toml" "$CONFIG_TOML"
    [[ -f "$dir/models.json"  ]] && cp "$dir/models.json"  "$MODELS_JSON"
}

# ---------------------------------------------------------------------------
# models.json 合并（python3）：按 slug upsert 三条 Kimi 模型元数据
# ---------------------------------------------------------------------------

py_merge_models() {
    have_python3 || die "需要 python3 才能更新 models.json"
    python3 - "$MODELS_JSON" <<'PY'
import json, os, sys

path = sys.argv[1]

LEVELS = [
    {"effort": "low",  "description": "Light reasoning"},
    {"effort": "high", "description": "Enhanced reasoning"},
    {"effort": "max",  "description": "Deep reasoning"},
]

def entry(slug, display, desc, ctx, priority):
    return {
        "slug": slug,
        "display_name": display,
        "description": desc,
        "default_reasoning_level": "high",
        "supported_reasoning_levels": [dict(x) for x in LEVELS],
        "shell_type": "shell_command",
        "visibility": "list",
        "supported_in_api": True,
        "priority": priority,
        "base_instructions": "",
        "supports_reasoning_summaries": True,
        "default_reasoning_summary": "none",
        "support_verbosity": False,
        "truncation_policy": {"mode": "bytes", "limit": 10000},
        "context_window": ctx,
        "max_context_window": ctx,
        "effective_context_window_percent": 95,
        "supports_parallel_tool_calls": True,
        "experimental_supported_tools": [],
        "input_modalities": ["text", "image"],
    }

KIMI_MODELS = [
    entry("k3",                "K3",             "K3，1M 上下文",          1048576, 0),
    entry("k3-256k",           "K3 256K",        "K3 256K 上下文",         262144, 1),
    entry("kimi-for-coding",   "Kimi For Coding", "Kimi For Coding，最高 1M 上下文", 1048576, 2),
]

if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
else:
    data = {"models": []}

models = data.setdefault("models", [])
if not isinstance(models, list):
    sys.exit("models.json 中 models 字段不是数组")

index = {m.get("slug"): i for i, m in enumerate(models) if isinstance(m, dict)}
for m in KIMI_MODELS:
    if m["slug"] in index:
        models[index[m["slug"]]] = m
    else:
        models.append(m)

out = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
json.loads(out)  # 写回前自检

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(out)
os.replace(tmp, path)
PY
}

# ---------------------------------------------------------------------------
# config.toml 编辑（python3）：文本级精准修改，保留其余所有内容
#   $1=mode(kimi|deepseek)  $2=model slug  $3=base_url  $4=token(仅 kimi 用)
# ---------------------------------------------------------------------------

py_edit_config() {
    have_python3 || die "需要 python3 才能更新 config.toml"
    python3 - "$CONFIG_TOML" "$1" "$2" "$3" "$4" <<'PY'
import os, re, sys

path, mode, slug, base_url, token = sys.argv[1:6]

with open(path, encoding="utf-8") as f:
    lines = f.readlines()

def first_section_index(ls):
    for i, ln in enumerate(ls):
        if re.match(r"\s*\[", ln):
            return i
    return len(ls)

HEADER_RE = re.compile(r"^\[(.+)\]\s*$")
# 段头内部：裸键段（字母数字 _-）或 "quoted" 段，以点分隔
HEADER_INNER_RE = re.compile(r'^(([\w-]+|"[^"]*"))(\.(([\w-]+|"[^"]*")))*$')

def structural_problems(content, mode):
    """无 tomllib 时的兜底检查：段头格式、重复段头、必备顶层键、必备段。"""
    problems = []
    headers = []
    for n, ln in enumerate(content.splitlines(), 1):
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        m = HEADER_RE.match(ln)
        if m:
            if not HEADER_INNER_RE.match(m.group(1)):
                problems.append("第 %d 行段头非法: %s" % (n, s))
            headers.append(m.group(1))
    dup = sorted({h for h in headers if headers.count(h) > 1})
    if dup:
        problems.append("存在重复段头: %s" % ", ".join(dup))
    for key in ("model", "model_provider", "model_catalog_json"):
        if not re.search(r"^\s*" + re.escape(key) + r"\s*=", content, re.M):
            problems.append("缺少顶层键: %s" % key)
    if mode == "kimi" and not re.search(r"^\[model_providers\.kimi\]\s*$", content, re.M):
        problems.append("缺少 [model_providers.kimi] 段")
    return problems

# 1) 顶层键：model / model_provider / model_catalog_json，存在则替换，不存在则补在顶层区域末尾
top_keys = {
    "model": slug,
    "model_provider": mode,
    "model_catalog_json": "~/.codex/models.json",
}
cut = first_section_index(lines)
top, rest = lines[:cut], lines[cut:]
for key, val in top_keys.items():
    pat = re.compile(r"^\s*" + re.escape(key) + r"\s*=")
    done = False
    for i, ln in enumerate(top):
        if pat.match(ln):
            top[i] = '%s = "%s"\n' % (key, val)
            done = True
            break
    if not done:
        top.append('%s = "%s"\n' % (key, val))
lines = top + rest

# 2) 删除旧的 [model_providers.kimi] 段（整段，到下一个 [ 头或文件尾）
if mode == "kimi":
    header = re.compile(r"^\s*\[\s*model_providers\.kimi\s*\]")
    start = None
    for i, ln in enumerate(lines):
        if header.match(ln):
            start = i
            break
    if start is not None:
        end = len(lines)
        for j in range(start + 1, len(lines)):
            if re.match(r"\s*\[", lines[j]):
                end = j
                break
        del lines[start:end]

    def toml_str(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')

    lines.append("\n[model_providers.kimi]\n")
    lines.append('name = "Kimi"\n')
    lines.append('base_url = "%s"\n' % toml_str(base_url))
    lines.append('wire_api = "responses"\n')
    lines.append('experimental_bearer_token = "%s"\n' % toml_str(token))

content = "".join(lines)

# 3) 写回前校验：有 tomllib 做完整 TOML 语法校验；
#    没有（python < 3.11）则做结构自检：段头格式合法、无重复段头、必备键齐全。
try:
    import tomllib
    tomllib.loads(content)
except ImportError:
    problems = structural_problems(content, mode)
    if problems:
        sys.stderr.write("config.toml 结构自检失败:\n  - " + "\n  - ".join(problems) + "\n")
        sys.exit(1)
except Exception as e:
    sys.stderr.write("config.toml 语法校验失败: %s\n" % e)
    sys.exit(1)

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(content)
os.replace(tmp, path)
PY
}

# ---------------------------------------------------------------------------
# 写入后整体验证
# ---------------------------------------------------------------------------

validate_all() {
    if ! have_python3; then
        log "警告: 无 python3，跳过写入后校验"
        return 0
    fi
    # EXPECT_KIMI_MODELS=1 时（切换到 Kimi）额外要求 models.json 含三条 Kimi 模型
    python3 - "$CONFIG_TOML" "$MODELS_JSON" "${EXPECT_KIMI_MODELS:-0}" <<'PY'
import json, re, sys

toml_path, json_path, expect_kimi = sys.argv[1:4]

HEADER_RE = re.compile(r"^\[(.+)\]\s*$")
HEADER_INNER_RE = re.compile(r'^(([\w-]+|"[^"]*"))(\.(([\w-]+|"[^"]*")))*$')

def structural_problems(content):
    problems = []
    headers = []
    for n, ln in enumerate(content.splitlines(), 1):
        s = ln.strip()
        if not s or s.startswith("#"):
            continue
        m = HEADER_RE.match(ln)
        if m:
            if not HEADER_INNER_RE.match(m.group(1)):
                problems.append("第 %d 行段头非法: %s" % (n, s))
            headers.append(m.group(1))
    dup = sorted({h for h in headers if headers.count(h) > 1})
    if dup:
        problems.append("存在重复段头: %s" % ", ".join(dup))
    for key in ("model", "model_provider"):
        if not re.search(r"^\s*" + re.escape(key) + r"\s*=", content, re.M):
            problems.append("缺少顶层键: %s" % key)
    return problems

content = open(toml_path, encoding="utf-8").read()
try:
    import tomllib
    tomllib.loads(content)
except ImportError:
    problems = structural_problems(content)
    if problems:
        sys.stderr.write("config.toml 结构自检失败:\n  - " + "\n  - ".join(problems) + "\n")
        sys.exit(1)
except Exception as e:
    sys.stderr.write("config.toml 校验失败: %s\n" % e)
    sys.exit(1)

try:
    with open(json_path, encoding="utf-8") as f:
        data = json.load(f)
    if expect_kimi == "1":
        slugs = {m.get("slug") for m in data.get("models", []) if isinstance(m, dict)}
        missing = {"k3", "k3-256k", "kimi-for-coding"} - slugs
        if missing:
            sys.stderr.write("models.json 缺少模型条目: %s\n" % ", ".join(sorted(missing)))
            sys.exit(1)
except FileNotFoundError:
    pass
except Exception as e:
    sys.stderr.write("models.json 校验失败: %s\n" % e)
    sys.exit(1)
PY
}

# 读取现有 [model_providers.kimi] 段中的 token（便于留空复用）
get_existing_kimi_token() {
    have_python3 || return 0
    python3 - "$CONFIG_TOML" <<'PY' || true
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
m = re.search(r"^\[model_providers\.kimi\]\s*$", text, re.M)
if not m:
    sys.exit(0)
section = text[m.end():]
nxt = re.search(r"^\[", section, re.M)
if nxt:
    section = section[:nxt.start()]
t = re.search(r'experimental_bearer_token\s*=\s*"([^"]*)"', section)
if t:
    print(t.group(1))
PY
}

# ---------------------------------------------------------------------------
# 各菜单动作
# ---------------------------------------------------------------------------

switch_kimi() { # $1=slug
    local slug="$1" token="" existing="" bdir
    existing="$(get_existing_kimi_token)"
    if [[ -n "$existing" ]]; then
        log "检测到现有 Kimi Key: $(mask "$existing")"
        read -r -s -p "请输入 Kimi API Key（留空则沿用现有）: " token || true
        log ""
        [[ -z "$token" ]] && token="$existing"
    else
        read -r -s -p "请输入 Kimi API Key（sk-...）: " token || true
        log ""
    fi
    [[ -n "$token" ]] || die "API Key 不能为空"

    bdir="$(backup_current "switch-kimi-$slug")"
    log "已备份当前配置到: $bdir"

    EXPECT_KIMI_MODELS=1
    export EXPECT_KIMI_MODELS
    if ! py_merge_models; then
        restore_from "$bdir"; die "models.json 更新失败，已从备份还原"
    fi
    if ! py_edit_config kimi "$slug" "$KIMI_BASE_URL" "$token"; then
        restore_from "$bdir"; die "config.toml 更新失败，已从备份还原"
    fi
    if ! validate_all; then
        restore_from "$bdir"; die "写入后校验失败，已从备份还原"
    fi

    log ""
    log "✔ 已切换到 Kimi: model=$slug, provider=kimi"
    log "  验证: 运行 codex，启动信息应显示 model: $slug / provider: kimi"
}

switch_deepseek() {
    grep -q '^\[model_providers\.deepseek\]' "$CONFIG_TOML" 2>/dev/null \
        || die "未找到 [model_providers.deepseek] 配置段，无法切回"

    local slug="deepseek-flash"
    if [[ -f "$CODEX_HOME/backup-deepseek/manifest.txt" ]]; then
        slug="$(grep -m1 '^model_slug=' "$CODEX_HOME/backup-deepseek/manifest.txt" | cut -d= -f2 || true)"
        [[ -z "$slug" ]] && slug="deepseek-flash"
    fi

    local bdir
    bdir="$(backup_current "switch-deepseek")"
    log "已备份当前配置到: $bdir"

    if ! py_edit_config deepseek "$slug" "" ""; then
        restore_from "$bdir"; die "config.toml 更新失败，已从备份还原"
    fi
    if ! validate_all; then
        restore_from "$bdir"; die "写入后校验失败，已从备份还原"
    fi

    log ""
    log "✔ 已切换回 DeepSeek: model=$slug, provider=deepseek"
}

restore_flow() {
    local dirs=() i=0 dir
    if [[ -d "$BACKUP_ROOT" ]]; then
        while IFS= read -r dir; do
            dirs+=("$dir")
        done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
    fi
    [[ ${#dirs[@]} -gt 0 ]] || die "没有找到任何备份（$BACKUP_ROOT）"

    log "可选备份："
    local n=${#dirs[@]} pick
    for ((i = 0; i < n; i++)); do
        log "  $((i + 1))) $(basename "${dirs[$i]}")"
    done
    read -r -p "请选择要恢复的备份编号 [默认 $n = 最新]: " pick || true
    if [[ -z "$pick" ]]; then
        pick="$n"
    fi
    [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= n)) \
        || die "无效编号: $pick"
    dir="${dirs[$((pick - 1))]}"

    local bdir
    bdir="$(backup_current "pre-restore")"
    log "已先备份当前配置到: $bdir"
    restore_from "$dir"
    if ! validate_all; then
        restore_from "$bdir"; die "还原后校验失败，已恢复到还原前状态"
    fi
    log ""
    log "✔ 已恢复备份: $dir"
    log "  当前配置: provider=$(cfg_get model_provider), model=$(cfg_get model)"
}

# ---------------------------------------------------------------------------
# 主菜单
# ---------------------------------------------------------------------------

main() {
    [[ -f "$CONFIG_TOML" ]] || die "未找到 $CONFIG_TOML，请先运行一次 codex 再执行本脚本"
    have_python3  || log "警告: 未找到 python3，models.json 无法更新"
    have_tomllib  || log "警告: python3 无 tomllib（<3.11），TOML 校验降级为基础检查"

    local choice
    while true; do
        log ""
        log "=== Codex Kimi 配置工具 v$VERSION ==="
        log "Codex Home : $CODEX_HOME"
        log "当前配置   : provider=$(cfg_get model_provider), model=$(cfg_get model)"
        log ""
        log "  1) 配置 Kimi k3-256k         (推荐, 省配额, 256K 上下文, 需 Moderato 及以上)"
        log "  2) 配置 Kimi k3              (1M 上下文, 需 Moderato 及以上)"
        log "  3) 配置 Kimi kimi-for-coding (Andante 档可用, 最高 1M)"
        if grep -q '^\[model_providers\.deepseek\]' "$CONFIG_TOML" 2>/dev/null; then
            log "  4) 切换回 DeepSeek"
        fi
        log "  9) 恢复原始配置"
        log "  0) 退出"
        log ""
        read -r -p "> " choice || true

        case "$choice" in
            1) switch_kimi "k3-256k" ;;
            2) switch_kimi "k3" ;;
            3) switch_kimi "kimi-for-coding" ;;
            4) switch_deepseek ;;
            9) restore_flow ;;
            0|q|"") exit 0 ;;
            *) log "无效选项: $choice" ;;
        esac
    done
}

main "$@"
