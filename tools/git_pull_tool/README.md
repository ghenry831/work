# git_pull_tool - Gerrit 全量同步的自动化 Git 代码拉取工具

工具默认从 Gerrit 动态获取当前用户**有权限的全部项目**，自动克隆到本地根目录（如 `D:/git`）并切到最新分支拉取代码；本地已有的仓库（包括不在 Gerrit 列表中的）也会一并更新。新增仓库权限（如 `aaschans/app`）后，无需改任何配置，双击运行脚本即可自动克隆出 `D:/git/aaschans/app`。

## 功能特点

- **Gerrit 全量同步**：运行时执行 `ssh -p 29418 user@host gerrit ls-projects` 获取有权限的项目列表，新项目自动克隆，已有项目自动更新。
- **自动识别最新分支**：未指定分支时，自动从远程分支中按 `feature_YYMM_X` 规则选出最新分支。
- **支持分支后缀**：如 `feature_2609_A_gray`，判断时只取 `feature_2609_A` 前缀。
- **支持指定分支**：配置 `branch` 后，直接拉取指定分支。
- **并发拉取**：可配置并发数，批量拉取节省时间。
- **存量仓库更新**：本地根目录下已有但不在 Gerrit 列表中的仓库，也会一并切分支并拉取。
- **冲突识别**：只在真正发生冲突或切换失败时跳过并记录，不影响的本地改动不干预。
- **日志记录**：每次运行生成独立日志文件，方便排查。
- **模拟运行**：`--dry-run` 可先查看工具会如何处理而不修改仓库。
- **兼容旧模式**：`gerrit.enabled: false` 时退回纯 `repos[]` 列表模式，行为与旧版一致。

## 环境要求

- Windows 10
- Python 3.8+
- Git（已加入系统 PATH）
- 已配置可通过 Gerrit 认证的 SSH 密钥，且能直接执行：
  ```bash
  ssh -p 29418 001096000@scm-sh.sdc.cs.icbc gerrit ls-projects
  ```

## 项目结构

```
git_pull_tool/
├── git_pull.py      # 主程序
├── config.json      # 配置文件
├── repos.txt        # 可选：旧模式仓库路径列表模板
└── README.md        # 使用说明
```

## 快速开始

### 1. 填写 Gerrit 配置

编辑 `config.json` 的 `gerrit` 段（只需一次）：

```json
{
  "gerrit": {
    "user": "001096000",
    "host": "scm-sh.sdc.cs.icbc",
    "port": 29418,
    "clone_root": "D:/git",
    "enabled": true
  }
}
```

### 2. 运行

```cmd
python git_pull.py --config config.json
```

模拟运行（不修改任何仓库）：

```cmd
python git_pull.py --config config.json --dry-run
```

运行流程：

1. 通过 SSH 执行 `gerrit ls-projects`，获取你有权限的全部项目。
2. 对每个项目，本地路径 = `clone_root` + 项目名（如 `D:/git` + `aaschans/app` → `D:/git/aaschans/app`）。
3. 本地不存在 → 自动通过 SSH 克隆；已存在 → 切到最新分支并 `git pull`。
4. 扫描 `clone_root` 下已有但不在 Gerrit 列表中的仓库，也一并更新。
5. 输出汇总：总数 / 成功 / 新克隆 / 冲突 / 失败 / 跳过。

之后每当你在新申请了一个 Gerrit 仓库权限后，直接再运行一次脚本即可。

## 配置文件说明

```json
{
  "concurrency": 5,
  "remote": "origin",
  "branch_pattern": "^feature_(\\d{2})(\\d{2})_([A-Z])",
  "gerrit": {
    "user": "001096000",
    "host": "scm-sh.sdc.cs.icbc",
    "port": 29418,
    "clone_root": "D:/git",
    "enabled": true
  },
  "repos": []
}
```

| 字段 | 说明 |
|---|---|
| `concurrency` | 并发拉取数，默认 `5` |
| `remote` | 远程仓库名，默认 `origin` |
| `branch_pattern` | 识别最新分支的正则，默认匹配 `feature_YYMM_X` |
| `gerrit.user` | Gerrit SSH 用户名 |
| `gerrit.host` | Gerrit SSH 主机 |
| `gerrit.port` | Gerrit SSH 端口 |
| `gerrit.clone_root` | 本地仓库根目录，Gerrit 项目会按项目名克隆到其下 |
| `gerrit.enabled` | `true`（默认）时启用 Gerrit 全量同步模式；`false` 时退回旧模式 |
| `repos[].path` | 可选，指定额外仓库（如不在 `clone_root` 之下的仓库） |
| `repos[].branch` | 可选，固定拉取某分支；也可用于覆盖 Gerrit 同步项目中同路径仓库的分支 |
| `repos[].remote` | 可选，覆盖单个仓库的远程名 |

`repos[]` 在同步模式下是**可选的**：留空即可；其中位于 `clone_root` 之下的条目会与 Gerrit 项目按路径合并（其 `branch`/`remote` 生效），位于之外的条目作为额外仓库处理。

## 旧模式（不使用 Gerrit 同步）

将 `gerrit.enabled` 设为 `false`（或删除 `gerrit` 段），工具只处理 `repos[]` 中列出的仓库，行为与旧版一致。

也可以用 txt 文件初始化仓库列表：

```text
C:/work/repo1
C:/work/repo2
```

```cmd
python git_pull.py --init-txt repos.txt --output config.json
```

或者扫描某个目录下的所有 `.git` 仓库：

```cmd
python git_pull.py --scan C:/work --output config.json
```

## 最新分支判断规则

以远程分支：

```text
origin/feature_2608_B
origin/feature_2609_A
origin/feature_2609_B
origin/feature_2610_A
origin/feature_2609_A_gray
```

为例，工具会：

1. 提取每个分支的 `feature_YYMM_X` 前缀。
2. 比较年月，越大越新。
3. 同年月下比较后缀字母，越大越新（`A < B < C < D`）。
4. 最终选择 `feature_2610_A`。
5. 切分支时优先使用完全匹配的 `origin/feature_2610_A`；不存在时才用带后缀的变体。

## 命令行参数

```text
usage: git_pull.py [-h] [--config CONFIG] [--dry-run]
                   [--init-txt TXT] [--scan DIR]
                   [--output OUTPUT] [--force]

可选参数:
  -h, --help         显示帮助信息
  --config CONFIG    配置文件路径（默认: config.json）
  --dry-run          模拟运行，不修改仓库
  --init-txt TXT     从 txt 文件初始化配置（旧模式）
  --scan DIR         扫描目录生成配置（旧模式）
  --output OUTPUT    生成配置时的输出路径（默认: config.json）
  --force            覆盖已存在的输出配置文件
```

## Windows 10 定时任务（每天运行一次）

### 方式一：Windows 任务计划程序

1. 按 `Win + S`，搜索“任务计划程序”并打开。
2. 右侧点击“创建基本任务”。
3. 名称：`git_pull_daily`。
4. 触发器：选择“每天”。
5. 开始时间：例如 `09:00`。
6. 操作：选择“启动程序”。
7. 程序或脚本：填写 Python 解释器路径，例如：
   ```text
   C:\Python38\python.exe
   ```
8. 添加参数：
   ```text
   git_pull.py --config C:\path\to\git_pull_tool\config.json
   ```
9. 起始于：填写 `git_pull_tool` 所在目录，例如：
   ```text
   C:\path\to\git_pull_tool
   ```
10. 完成创建。

### 方式二：批处理脚本（供手动双击或配合计划任务使用）

创建 `run_daily.bat`：

```bat
@echo off
chcp 65001 >nul
cd /d C:\path\to\git_pull_tool
C:\Python38\python.exe git_pull.py --config config.json
pause
```

双击即可运行：自动发现 Gerrit 上有权限的新仓库并克隆，同时更新所有存量仓库。

## 日志

每次运行会在 `logs/` 目录下生成类似：

```text
logs/git_pull_20260822_093000.log
```

日志中包含每个仓库的处理结果和最终汇总。

## 常见问题

### 1. 命令行提示 `python` 不是内部命令

使用 Python 安装路径的完整路径调用，例如：

```cmd
C:\Python38\python.exe git_pull.py
```

或者在 Windows 上使用 Python 启动器：

```cmd
py -3.8 git_pull.py
```

### 2. 某些仓库失败怎么办

工具不会自动清理失败仓库的现场。请根据日志中的失败原因手动处理，例如解决冲突后继续运行。

### 3. 远程名不是 origin

在配置文件中设置 `remote` 字段，或给单个仓库设置 `repos[].remote`。

### 4. gerrit ls-projects 执行失败

- 确认能直接在命令行执行：`ssh -p 29418 001096000@scm-sh.sdc.cs.icbc gerrit ls-projects`。
- 确认本地 SSH 密钥已配置且 Gerrit 账号有相应权限。
- 命令超时时间为 120 秒，内网异常时可稍后重试。

### 5. 克隆或拉取卡死

git 命令默认 300 秒超时，超时会在日志中标记为该仓库失败，不影响其他仓库。

## 扩展预留

- 拉取成功后执行自定义 hook
- 失败时发送邮件/IM 通知
- Gerrit 项目过滤（include/exclude 前缀）
