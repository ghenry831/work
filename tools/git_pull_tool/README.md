# git_pull_tool - 自动化 Git 代码拉取工具

在公司内管理 30~40 个本地 Git 仓库时，可以借助本工具一键或定时批量拉取每个仓库的最新代码。

## 功能特点

- **可配置仓库列表**：通过 JSON 配置文件维护所有本地仓库路径。
- **自动识别最新分支**：未指定分支时，自动从远程分支中按 `feature_YYMM_X` 规则选出最新分支。
- **支持分支后缀**：如 `feature_2609_A_gray`，判断时只取 `feature_2609_A` 前缀。
- **支持指定分支**：配置 `branch` 后，直接拉取指定分支。
- **并发拉取**：可配置并发数，批量拉取节省时间。
- **自动克隆缺失仓库**：本地目录不存在时，可通过 Gerrit SSH 自动克隆并继续切到最新分支。
- **冲突识别**：只在真正发生冲突或切换失败时跳过并记录，不影响的本地改动不干预。
- **配置初始化**：支持从 txt 文件或扫描目录生成初始配置。
- **日志记录**：每次运行生成独立日志文件，方便排查。
- **模拟运行**：`--dry-run` 可先查看工具会如何处理而不修改仓库。

## 环境要求

- Windows 10
- Python 3.8+
- Git（已加入系统 PATH）

## 项目结构

```
git_pull_tool/
├── git_pull.py      # 主程序
├── config.json      # 配置文件
├── repos.txt        # 可选：仓库路径列表模板
└── README.md        # 使用说明
```

## 快速开始

### 1. 准备仓库路径

把本地所有 Git 仓库的路径按行写入 `repos.txt`，例如：

```text
C:/work/repo1
C:/work/repo2
D:/projects/repo3
```

### 2. 生成配置文件

```cmd
python git_pull.py --init-txt repos.txt --output config.json
```

或者扫描某个目录下的所有 `.git` 仓库：

```cmd
python git_pull.py --scan C:/work --output config.json
```

生成的 `config.json` 会自带一个 `gerrit` 模板（默认 `enabled: false`）。如果需要自动克隆缺失仓库，请填写 `user`、`host`、`clone_root` 等字段，并将 `enabled` 改为 `true`。

### 3. 运行拉取

```cmd
python git_pull.py --config config.json
```

模拟运行（不修改任何仓库）：

```cmd
python git_pull.py --config config.json --dry-run
```

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
  "repos": [
    { "path": "D:/git/aasaas/aasbi" },
    { "path": "D:/git/repo2", "branch": "feature_2609_A" },
    { "path": "D:/git/repo3" }
  ]
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
| `gerrit.clone_root` | 本地仓库根目录，用于从 `path` 推导 Gerrit 工程名 |
| `gerrit.enabled` | 是否开启缺失自动克隆，默认 `true` |
| `repos[].path` | 本地仓库路径，Windows 下可用 `/` 或 `\\` |
| `repos[].branch` | 可选，指定要拉取的分支；不填则自动找最新 |
| `repos[].remote` | 可选，覆盖单个仓库的远程名 |

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

## Gerrit 自动克隆

当配置文件中启用了 `gerrit` 段且某个仓库的本地目录不存在时，工具会尝试通过 SSH 从 Gerrit 自动克隆该仓库。

配置示例：

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

仓库名推导规则：

1. 取 `repos[].path`，例如 `D:/git/aasaas/aasbi`。
2. 取 `gerrit.clone_root`，例如 `D:/git`。
3. 用相对路径得到 Gerrit 工程名 `aasaas/aasbi`。
4. 拼接为 SSH 克隆地址：`ssh://001096000@scm-sh.sdc.cs.icbc:29418/aasaas/aasbi`。

前置条件：

- 本地已配置可通过 Gerrit 认证的 SSH 密钥。
- Git 已加入系统 PATH。
- `clone_root` 必须是所有待克隆仓库的公共根目录，且仓库路径必须位于其下。

克隆完成后，工具会继续按 `branch_pattern` 查找最新分支并执行 `git checkout` + `git pull`。

## 命令行参数

```text
usage: git_pull.py [-h] [--config CONFIG] [--dry-run]
                   [--init-txt TXT] [--scan DIR]
                   [--output OUTPUT] [--force]

可选参数:
  -h, --help         显示帮助信息
  --config CONFIG    配置文件路径（默认: config.json）
  --dry-run          模拟运行，不修改仓库
  --init-txt TXT     从 txt 文件初始化配置
  --scan DIR         扫描目录生成配置
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

双击即可运行。

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

### 4. 目录不存在时自动克隆失败

- 检查 `gerrit` 段是否填写完整：`user`、`host`、`port`、`clone_root`。
- 确认 `path` 位于 `clone_root` 之下，否则无法推导 Gerrit 工程名。
- 确认本地 SSH 密钥已配置，并且能直接访问 Gerrit，例如：
  ```bash
  ssh -p 29418 001096000@scm-sh.sdc.cs.icbc
  ```
- 克隆失败不会清理已创建的目录，请根据日志手动处理后再次运行。

## 扩展预留

- 支持 YAML/TOML 配置
- 拉取成功后执行自定义 hook
- 失败时发送邮件/IM 通知
