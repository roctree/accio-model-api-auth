# Accio Model API Auth

为 Accio Desktop 接入自定义模型 API 或本机 Codex ChatGPT 登录，同时保留 Accio 原有的历史会话、Skill、MCP、插件和浏览器工具能力。

> 这是非官方社区项目，与 Accio、阿里巴巴、OpenCode 或 OpenAI 无隶属关系。Accio 更新后，内部接口可能发生变化。

## 当前基线

当前版本已在 Windows 与 Accio Desktop 0.30.2 上验证：

- 模型请求转发到 OpenCode Go 的 `deepseek-v4-flash`。
- 历史会话、Skill、MCP、插件、频道和心跳请求转发到 Accio 原网关。
- Accio 浏览器工具调用可完成完整的调用与结果回传。
- 可通过 Codex App Server 使用本机 ChatGPT 托管登录，不需要复制 OAuth Token。
- Codex 模型列表从本机 App Server 动态读取，已验证文本、多轮对话和动态工具结果回传。
- OpenCode API Key 保存在 Windows 凭据管理器中，不写入源码或配置文件。
- Accio 本地网关口令在首次启动时随机生成，并保存在 Windows 凭据管理器中。

## 请求路径

```text
Accio Desktop
  -> 本地路由网关（127.0.0.1:18767）
     -> 模型请求：本地模型桥（127.0.0.1:18765）
        -> OpenAI-compatible API（例如 OpenCode Go）
        -> 或本机 Codex App Server（ChatGPT 托管登录）
     -> Accio 功能请求：phoenix-gw.alibaba.com
```

## 使用方法

环境要求：Windows、Node.js、已安装的 Accio Desktop。使用 Codex 登录时，还需要本机 Codex Desktop 或包含 `codex-code-mode-host.exe` 的完整 Codex 安装。

### 可视化配置

双击 `open_config_ui.cmd`，或者运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\accio_config_ui.ps1
```

界面可以配置：

- OpenAI-compatible API 地址。
- 模型名称，默认仍为 `deepseek-v4-flash`。
- API Key 认证，Key 保存到 Windows 凭据管理器。
- 无认证模式，用于本机 Ollama、vLLM 等兼容服务。
- Codex ChatGPT 登录模式，登录状态和模型列表由本机 Codex App Server 提供。

Codex 模式下可在界面中点击“登录 Codex”，登录完成后点击“刷新 Codex 登录和模型”。API 模式和 Codex 模式分别记住自己的地址与模型，切换时不会覆盖已经可用的 `deepseek-v4-flash` 配置。

非敏感配置保存在 `%LOCALAPPDATA%\AccioModelApiAuth\config.json`。点击“保存并启动 Accio”后，程序只重启本地模型桥并应用新配置；Accio 原网关路由保持不变。

### 命令行

首次使用时保存 OpenCode Go API Key：

```powershell
powershell -ExecutionPolicy Bypass -File .\accio_opencode_launcher.ps1 -StoreCredential
```

随后启动 Accio：

```powershell
powershell -ExecutionPolicy Bypass -File .\accio_opencode_launcher.ps1
```

只启动本地桥和路由网关：

```powershell
powershell -ExecutionPolicy Bypass -File .\accio_opencode_launcher.ps1 -BackendOnly
```

## 安全说明

- 不要把 API Key、Cookie、登录令牌或日志提交到仓库。
- 仓库不读取或导出 Codex、ChatGPT 或 Accio 的登录令牌。
- Codex OAuth 的保存与刷新由 Codex 自己完成，本项目只调用 App Server 的认证状态、模型和推理协议。
- 本地服务只监听 `127.0.0.1`。
- 公开问题报告中请先删除请求头、凭据和个人会话内容。

## Codex 适配方式

Accio 的工具调用会映射为 Codex 动态工具。Codex 发出工具请求后，本地桥先把 `functionCall` 返回给 Accio；Accio 执行 Skill、MCP、插件或浏览器工具并提交 `functionResponse` 后，本地桥再续接原 Codex turn。Codex 内置 shell、文件、Web、MCP 和子智能体工具不会被桥接给 Accio。

协议与认证依据：[Codex App Server](https://learn.chatgpt.com/docs/app-server) 和 [Codex authentication](https://learn.chatgpt.com/docs/auth)。
