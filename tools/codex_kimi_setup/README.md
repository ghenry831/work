# codex_kimi_setup - Codex 一键切换 Kimi 模型配置工具

仿 [DeepSeek 官方 Codex 配置脚本](https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/codex) 的体验，把 Codex 的模型配置一键切换到 Kimi（[Kimi 官方接入文档](https://www.kimi.com/code/docs/third-party-tools/codex.html)）。运行脚本、选一个菜单项、粘贴 API Key，即完成全部配置；Kimi 与 DeepSeek 配置长期共存，可随时秒级互切，不用重新输 Key。

## 功能特点

- **一键切换**：自动完成 models.json 模型目录合并、config.toml 精准修改，无需手工编辑任何配置文件。
- **三个 Kimi 模型可选**：`k3-256k`（256K，省配额，推荐）、`k3`（1M 上下文）、`kimi-for-coding`（Andante 会员档可用，最高 1M）。
- **配置共存**：`[model_providers.deepseek]` 段及其 Key 原样保留，菜单可随时切回 DeepSeek。
- **只改必要字段**：plugins、mcp_servers、projects、`web_search` 等现有配置全部原样保留。
- **备份可回滚**：每次切换前自动备份 `config.toml` / `models.json` 到 `~/.codex/backup-kimi/<时间戳>/`，菜单 9 可随时恢复。
- **写入前校验**：TOML / JSON 语法校验失败立即中止并自动从备份还原，不留半成品。
- **幂等**：重复运行安全；已有 Kimi Key 时可留空直接沿用。

## 环境要求

- macOS（或 Linux）
- 已安装 Codex CLI 或 ChatGPT 桌面端，并至少运行过一次（`~/.codex/config.toml` 已存在）
- `python3`（用于 models.json 合并与 TOML 校验；macOS 自带）
- 一枚 Kimi 会员 API Key（`sk-kimi-...`），获取方式见 [Kimi 开放平台](https://www.kimi.com/code)

## 项目结构

```
codex_kimi_setup/
├── setup.sh      # 主脚本
└── README.md     # 使用说明
```

## 快速开始

```bash
bash setup.sh
```

输出示例：

```
=== Codex Kimi 配置工具 v1.0.0 ===
Codex Home : /Users/xxx/.codex
当前配置   : provider=deepseek, model=deepseek-flash

  1) 配置 Kimi k3-256k         (推荐, 省配额, 256K 上下文, 需 Moderato 及以上)
  2) 配置 Kimi k3              (1M 上下文, 需 Moderato 及以上)
  3) 配置 Kimi kimi-for-coding (Andante 档可用, 最高 1M)
  4) 切换回 DeepSeek
  9) 恢复原始配置
  0) 退出
```

选择后按提示粘贴 API Key（输入不回显）。完成后运行 `codex`，启动信息应显示 `model: k3-256k`、`provider: kimi`。

## 脚本做了什么

1. 备份当前 `config.toml`、`models.json` 到 `~/.codex/backup-kimi/<时间戳>/`。
2. `models.json`：按 slug 合并写入 `k3`、`k3-256k`、`kimi-for-coding` 三条模型元数据（字段与 Kimi 官方文档一致），已有条目（如 DeepSeek）全部保留。
3. `config.toml`：
   - 顶层 `model` / `model_provider = "kimi"` / `model_catalog_json` 更新为所选值；
   - 追加（或替换）`[model_providers.kimi]` 段：`base_url = "https://api.kimi.com/coding/v1"`、`wire_api = "responses"`、`experimental_bearer_token = "<你的 Key>"`（明文写入，与 DeepSeek 官方脚本行为一致）。
4. 写入前做 TOML / JSON 语法校验，失败自动还原。

## 菜单说明

| 选项 | 说明 |
|---|---|
| 1 | 切换到 `k3-256k`，256K 上下文更省配额，**需 Kimi 会员 Moderato 及以上档位** |
| 2 | 切换到 `k3`，1M 上下文，需 Moderato 及以上档位 |
| 3 | 切换到 `kimi-for-coding`，**Andante 档即可用**，最高 1M 上下文 |
| 4 | 切回 DeepSeek（使用原配置段与 Key，出现在检测到 DeepSeek 配置时） |
| 9 | 从 `backup-kimi/` 的备份恢复 config.toml / models.json |
| 0 | 退出 |

## 模型与会员档位对照

| 模型 | 上下文 | 思考档位 | 可用会员档 |
|---|---|---|---|
| `k3-256k` | 256K | low / high / max | Moderato 及以上 |
| `k3` | 1M | low / high / max | Moderato 及以上 |
| `kimi-for-coding` | 最高 1M | low / high / max | Andante 及以上 |

## 切换回 DeepSeek

方式一（推荐）：运行本脚本选菜单 4，秒切回 DeepSeek，Kimi 配置保留。

方式二：重跑 DeepSeek 官方脚本，两家脚本都会保留对方的配置段，可互操作。

## 常见问题

### 1. 界面模型列表里 DeepSeek 和 Kimi 模型都在，能直接选吗？

**同一家内部可以，跨家不行。** Codex 的 `model_provider` 是全局唯一的：所有请求都发往当前 provider 的 base_url，模型目录条目不携带 provider 归属。切成 Kimi 后在界面里选 `deepseek-v4-pro`，请求会打到 Kimi 端点并报错。跨家切换请用本脚本菜单（或 DeepSeek 脚本）；Kimi 家的 `k3` / `k3-256k` / `kimi-for-coding` 之间可在界面自由切换。

### 2. 切换后 codex 仍显示旧模型？

完全退出并重启 Codex（桌面 App 需 Cmd+Q 后重开），它会重新读取 `~/.codex/config.toml`。

### 3. 提示 "Model metadata not found"？

说明 models.json 中缺少对应模型条目。重跑一次本脚本（选任意 Kimi 选项）即可补齐目录。

### 4. API Key 存在哪里？安全吗？

按 DeepSeek 官方脚本同款方式，明文写入 `~/.codex/config.toml` 的 `experimental_bearer_token` 字段。该文件权限建议保持 600（仅本人可读）。Kimi 官方更推荐环境变量方式（`env_key = "KIMI_API_KEY"` + shell rc 里 export），如需改用环境变量，可手工把 `experimental_bearer_token` 行删掉、改为 `env_key` 并在 `~/.zshrc` 中 export Key；注意两种方式不要同时配置。

### 5. 提示没有 python3？

macOS 自带 `/usr/bin/python3`（首次调用会引导安装 Command Line Tools）。缺少时脚本降级为基础检查，但 models.json 合并必须依赖 python3。

### 6. 想自定义 Codex Home 路径？

```bash
CODEX_HOME=/path/to/codex bash setup.sh
```

## 与 DeepSeek 官方脚本的关系

两者目标相同、互为补充：DeepSeek 脚本负责接入 DeepSeek，本脚本负责接入 Kimi。任何一方执行后都不会删除另一方的 provider 配置段和 Key，所以可以来回切换、也可以两个脚本都保留。
