# Accio Model API Auth

为 Accio Desktop 接入自定义模型 API 或本机 Codex ChatGPT 登录，也可以一键恢复 Accio 官方原生认证，同时保留 Accio 原有的历史会话、Skill、MCP、插件和浏览器工具能力。

> 这是非官方社区项目，与 Accio、阿里巴巴、OpenCode 或 OpenAI 无隶属关系。Accio 更新后，内部接口可能发生变化。

## 当前基线

当前版本的 Accio 路由基线已在 Windows 与 Accio Desktop 0.30.2 上验证；火山 Coding Plan 的请求格式、流式响应和工具续轮已通过本地模拟接口验证，真实套餐可用性仍取决于账号、Key 与控制台开放的模型：

- API 服务商可选择 OpenCode Go、火山引擎 Coding Plan 或自定义 OpenAI-compatible API；各服务商分别保存地址、模型、思考模式和凭据。
- OpenCode Go 的 `deepseek-v4-flash` 可选择关闭、低、高或最高思考模式。
- 火山 Coding Plan 固定使用套餐专用接口，可直接选择当前官方 Code 模型或 `ark-code-latest`，思考模式可跟随模型默认、开启或关闭。
- 历史会话、Skill、MCP、插件、频道和心跳请求转发到 Accio 原网关。
- Accio 浏览器工具调用可完成完整的调用与结果回传。
- 可通过 Codex App Server 使用本机 ChatGPT 托管登录，不需要复制 OAuth Token。
- Codex 模型列表和每个模型支持的思考强度从本机 App Server 动态读取，已验证文本、多轮对话和动态工具结果回传。
- Accio 的模型选择位置会显示实际 API 服务商、上游返回的模型（若接口提供）与思考模式，切换配置后自动刷新。
- 可切换回 Accio 官方原生认证，使用 Accio 自己的登录、官方模型和积分；已有 OpenCode 与 Codex 配置不会被删除。
- OpenCode、火山 Coding Plan 和自定义 API 的 Key 分别保存在 Windows 凭据管理器中，互不覆盖，也不写入源码或配置文件。
- Accio 本地网关口令在首次启动时随机生成，并保存在 Windows 凭据管理器中。

## 请求路径

```text
Accio Desktop
  -> 本地路由网关（127.0.0.1:18767）
     -> 模型请求：本地模型桥（127.0.0.1:18765）
        -> OpenAI-compatible API（OpenCode Go、火山 Coding Plan 或自定义服务）
        -> 或本机 Codex App Server（ChatGPT 托管登录）
     -> 模型显示目录：读取本地模型桥当前状态，只改 Accio 显示名称
     -> Accio 功能请求：phoenix-gw.alibaba.com
```

## 使用方法

环境要求：Windows、Node.js、已安装的 Accio Desktop。使用 Codex 登录时，还需要本机 Codex Desktop 或包含 `codex-code-mode-host.exe` 的完整 Codex 安装。

### 可视化配置

双击 `open_config_ui.cmd`，或者运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\accio_config_ui.ps1
```

界面提供 3 种接入方式：

- OpenAI-compatible API：在内部选择 OpenCode Go、火山引擎 Coding Plan 或自定义服务。两个套餐服务使用固定的专用地址；自定义服务可填写地址，并可取消 API Key 认证以连接本机 Ollama、vLLM 等兼容服务。
- Codex ChatGPT 登录：登录状态、模型列表和思考强度由本机 Codex App Server 提供。
- Accio 官方原生认证：不经过本地模型桥或路由网关，思考模式由 Accio 官方控制。

OpenCode Go 与自定义 API 保留 DeepSeek 格式的“关闭、低、高、最高”：关闭发送 `thinking.type=disabled`；其余发送 `thinking.type=enabled` 与对应的 `reasoning_effort=low|high|max`。火山 Coding Plan 的“思考程度”会随模型变化，只显示已确认的档位：DeepSeek V4 Flash 支持低、高、最高，DeepSeek V4 Pro 支持高、最高，Doubao Seed 2.0 Lite 支持低、中、高，GLM 5.2/5.3 和 MiniMax M3 按各自能力显示；未确认能力的模型与 `ark-code-latest` 只提供“跟随模型默认”。选择具体档位时发送 `thinking.type=enabled` 与对应的 `reasoning_effort`，选择开关时只发送 `thinking.type`。工具调用续轮会把模型上一轮返回的 `reasoning_content` 原样带回。

火山 Coding Plan 使用完整请求地址 `https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions`。不要改成普通方舟 `/api/v3`：普通地址不会消耗 Coding Plan 套餐额度，并可能产生额外 API 费用。模型预设依据当前官方列表，同时保留手动填写能力；最终可用模型以火山控制台为准。接口依据：[Coding Plan 套餐与支持模型](https://docs.volcengine.com/docs/82379/1925114?lang=zh) 和 [Coding Plan 常见问题](https://docs.volcengine.com/docs/82379/2165245?lang=zh)。

Codex 模式下可在界面中点击“登录 Codex”，登录完成后点击“刷新 Codex 登录和模型”。选择模型后，“思考模式”只显示该模型实际支持的 `low`、`medium`、`high`、`xhigh`、`max` 或 `ultra`；切换到不支持当前强度的模型时自动使用该模型的默认值。OpenCode、火山、自定义 API 和 Codex 分别记住自己的地址、模型与思考模式，来回切换不会覆盖其他服务商的配置或 Key。

非敏感配置保存在 `%LOCALAPPDATA%\AccioModelApiAuth\config.json`。点击“保存并重启 Accio”后会先提示重启风险，再应用所选认证方式。切换到官方原生认证时，Accio 不再注入 `GATEWAY_BASE_URL`，模型、认证和积分全部恢复为 Accio 官方逻辑；切回 API 或 Codex 模式时继续使用之前保存的地址、模型和凭据，无需重新填写。

首次启用真实模型显示后需要重启一次 Accio。此后 Accio 模型选择位置会以“`实际模型 · 思考模式 | Accio: 原名称`”显示，并每 5 秒从本地模型桥刷新。

### 托盘与快捷方式

双击 `install_tray.cmd` 可安装当前用户的常驻托盘，并创建：

- 桌面快捷方式“Accio 模型认证配置”。
- 开始菜单快捷方式“Accio 模型认证配置”。
- Windows 登录启动项“Accio 模型认证托盘”。

托盘使用 Accio 自带图标。双击图标打开认证配置；右键菜单可查看当前认证方式、打开配置、应用当前配置并重启 Accio、启动 Accio 或退出托盘。托盘为单实例，退出托盘不会关闭 Accio。

### 命令行

命令行保存当前所选 API 服务商的 Key：

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
