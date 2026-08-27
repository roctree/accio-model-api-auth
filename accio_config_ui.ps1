Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$openCodeCredentialTarget = "AccioOpenCodeGoApiKey"
$volcengineCredentialTarget = "AccioVolcengineCodingPlanApiKey"
$customApiCredentialTarget = "AccioCustomOpenAiApiKey"
$configDirectory = Join-Path $env:LOCALAPPDATA "AccioModelApiAuth"
$configPath = Join-Path $configDirectory "config.json"
$launcherPath = Join-Path $PSScriptRoot "accio_opencode_launcher.ps1"
$codexStatusScript = Join-Path $PSScriptRoot "accio_codex_status.js"
$nodeExe = "C:\Program Files\nodejs\node.exe"
$openCodeProvider = "opencode_go"
$volcengineProvider = "volcengine_coding_plan"
$customApiProvider = "custom_openai"
$defaultEndpoint = "https://opencode.ai/zen/go/v1/chat/completions"
$volcengineEndpoint = "https://ark.cn-beijing.volces.com/api/coding/v3/chat/completions"
$codexEndpoint = "codex-app-server://local"
$nativeEndpoint = "accio-native://official"
$nativeModel = "由 Accio 官方管理"
$defaultModel = "deepseek-v4-flash"
$defaultVolcengineModel = "deepseek-v4-flash"
$defaultCodexModel = "gpt-5.6-sol"
$openCodeModels = @("deepseek-v4-flash")
$volcengineModels = @(
    "deepseek-v4-flash",
    "deepseek-v4-pro",
    "doubao-seed-evolving",
    "doubao-seed-2.1-turbo",
    "doubao-seed-2.0-lite",
    "glm-5.3",
    "glm-5.2",
    "kimi-k2.7-code",
    "minimax-m3",
    "ark-code-latest"
)
$lastApiProvider = $openCodeProvider
$lastOpenCodeModel = $defaultModel
$lastOpenCodeReasoningEffort = "high"
$lastOpenCodeUseApiKey = $true
$lastVolcengineModel = $defaultVolcengineModel
$lastVolcengineReasoningEffort = "default"
$lastCustomEndpoint = ""
$lastCustomModel = ""
$lastCustomReasoningEffort = "disabled"
$lastCustomUseApiKey = $true
$lastCodexModel = $defaultCodexModel
$lastCodexReasoningEffort = ""
$codexImageEnabled = $false
$codexModelsById = @{}
$previousAuthIndex = -1
$previousApiProviderIndex = -1
$updatingApiProvider = $false

if (-not ("AccioModelApiAuth.NativeCredential" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace AccioModelApiAuth {
    public static class NativeCredential {
        private const uint CRED_TYPE_GENERIC = 1;
        private const uint CRED_PERSIST_LOCAL_MACHINE = 2;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL {
            public uint Flags;
            public uint Type;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
            [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
            [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
        }

        [DllImport("Advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite([In] ref CREDENTIAL credential, uint flags);

        public static void Write(string target, string secret) {
            byte[] blob = Encoding.Unicode.GetBytes(secret);
            GCHandle handle = GCHandle.Alloc(blob, GCHandleType.Pinned);
            try {
                CREDENTIAL credential = new CREDENTIAL {
                    Type = CRED_TYPE_GENERIC,
                    TargetName = target,
                    CredentialBlobSize = (uint)blob.Length,
                    CredentialBlob = handle.AddrOfPinnedObject(),
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    UserName = "Accio Model API"
                };
                if (!CredWrite(ref credential, 0)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            } finally {
                Array.Clear(blob, 0, blob.Length);
                handle.Free();
            }
        }
    }
}
'@
}

function Get-CodexExecutable {
    $binRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    if (Test-Path -LiteralPath $binRoot) {
        $candidate = Get-ChildItem -LiteralPath $binRoot -Directory |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                $codexPath = Join-Path $_.FullName "codex.exe"
                $hostPath = Join-Path $_.FullName "codex-code-mode-host.exe"
                if ((Test-Path -LiteralPath $codexPath) -and (Test-Path -LiteralPath $hostPath)) {
                    $codexPath
                }
            } |
            Select-Object -First 1
        if ($candidate) {
            return $candidate
        }
    }
    $command = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        $hostPath = Join-Path (Split-Path -Parent $command.Source) "codex-code-mode-host.exe"
        if (Test-Path -LiteralPath $hostPath) {
            return $command.Source
        }
    }
    throw "未找到包含 codex-code-mode-host.exe 的完整 Codex 安装"
}

function Get-CodexStatus {
    if (-not (Test-Path -LiteralPath $nodeExe)) {
        throw "未找到 Node.js：$nodeExe"
    }
    if (-not (Test-Path -LiteralPath $codexStatusScript)) {
        throw "未找到 Codex 状态脚本：$codexStatusScript"
    }
    $codexExe = Get-CodexExecutable
    $previousCodexExe = $env:ACCIO_CODEX_EXE
    try {
        $env:ACCIO_CODEX_EXE = $codexExe
        $output = & $nodeExe $codexStatusScript 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String)
        }
        return ($output | Select-Object -Last 1 | ConvertFrom-Json)
    } finally {
        if ($null -eq $previousCodexExe) {
            Remove-Item Env:ACCIO_CODEX_EXE -ErrorAction SilentlyContinue
        } else {
            $env:ACCIO_CODEX_EXE = $previousCodexExe
        }
    }
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Accio 模型接入配置"
$form.ClientSize = New-Object System.Drawing.Size(660, 655)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 248, 252)

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Location = New-Object System.Drawing.Point(0, 0)
$headerPanel.Size = New-Object System.Drawing.Size(660, 82)
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$form.Controls.Add($headerPanel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Accio 模型接入配置"
$titleLabel.Location = New-Object System.Drawing.Point(28, 17)
$titleLabel.Size = New-Object System.Drawing.Size(500, 30)
$titleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::White
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "模型可切换；历史会话、Skill、MCP、插件和工具仍走 Accio 原网关"
$subtitleLabel.Location = New-Object System.Drawing.Point(30, 50)
$subtitleLabel.Size = New-Object System.Drawing.Size(600, 20)
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
$headerPanel.Controls.Add($subtitleLabel)

$authLabel = New-Object System.Windows.Forms.Label
$authLabel.Text = "接入方式"
$authLabel.Location = New-Object System.Drawing.Point(30, 105)
$authLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($authLabel)

$authComboBox = New-Object System.Windows.Forms.ComboBox
$authComboBox.Location = New-Object System.Drawing.Point(30, 130)
$authComboBox.Size = New-Object System.Drawing.Size(600, 28)
$authComboBox.DropDownStyle = "DropDownList"
[void]$authComboBox.Items.Add("OpenAI-compatible API（API Key 可选）")
[void]$authComboBox.Items.Add("Codex ChatGPT 登录（由本机 Codex 托管）")
[void]$authComboBox.Items.Add("Accio 官方原生认证（官方模型与积分）")
$form.Controls.Add($authComboBox)

$apiProviderLabel = New-Object System.Windows.Forms.Label
$apiProviderLabel.Text = "API 服务商"
$apiProviderLabel.Location = New-Object System.Drawing.Point(30, 174)
$apiProviderLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($apiProviderLabel)

$apiProviderComboBox = New-Object System.Windows.Forms.ComboBox
$apiProviderComboBox.Location = New-Object System.Drawing.Point(30, 199)
$apiProviderComboBox.Size = New-Object System.Drawing.Size(600, 28)
$apiProviderComboBox.DropDownStyle = "DropDownList"
[void]$apiProviderComboBox.Items.Add("OpenCode Go")
[void]$apiProviderComboBox.Items.Add("火山引擎 Coding Plan")
[void]$apiProviderComboBox.Items.Add("自定义 OpenAI-compatible API")
$form.Controls.Add($apiProviderComboBox)

$endpointLabel = New-Object System.Windows.Forms.Label
$endpointLabel.Text = "API 地址"
$endpointLabel.Location = New-Object System.Drawing.Point(30, 239)
$endpointLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($endpointLabel)

$endpointTextBox = New-Object System.Windows.Forms.TextBox
$endpointTextBox.Location = New-Object System.Drawing.Point(30, 264)
$endpointTextBox.Size = New-Object System.Drawing.Size(600, 28)
$form.Controls.Add($endpointTextBox)

$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = "模型名称"
$modelLabel.Location = New-Object System.Drawing.Point(30, 310)
$modelLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($modelLabel)

$modelComboBox = New-Object System.Windows.Forms.ComboBox
$modelComboBox.Location = New-Object System.Drawing.Point(30, 335)
$modelComboBox.Size = New-Object System.Drawing.Size(255, 28)
$modelComboBox.DropDownStyle = "DropDown"
$modelComboBox.AutoCompleteMode = "SuggestAppend"
$modelComboBox.AutoCompleteSource = "ListItems"
$form.Controls.Add($modelComboBox)

$reasoningEffortLabel = New-Object System.Windows.Forms.Label
$reasoningEffortLabel.Text = "思考程度"
$reasoningEffortLabel.Location = New-Object System.Drawing.Point(300, 310)
$reasoningEffortLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($reasoningEffortLabel)

$reasoningEffortComboBox = New-Object System.Windows.Forms.ComboBox
$reasoningEffortComboBox.Location = New-Object System.Drawing.Point(300, 335)
$reasoningEffortComboBox.Size = New-Object System.Drawing.Size(120, 28)
$reasoningEffortComboBox.DropDownStyle = "DropDownList"
$form.Controls.Add($reasoningEffortComboBox)

$codexRefreshButton = New-Object System.Windows.Forms.Button
$codexRefreshButton.Text = "刷新 Codex 登录和模型"
$codexRefreshButton.Location = New-Object System.Drawing.Point(434, 334)
$codexRefreshButton.Size = New-Object System.Drawing.Size(196, 30)
$form.Controls.Add($codexRefreshButton)

$apiKeyLabel = New-Object System.Windows.Forms.Label
$apiKeyLabel.Text = "API Key"
$apiKeyLabel.Location = New-Object System.Drawing.Point(30, 381)
$apiKeyLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($apiKeyLabel)

$apiKeyAuthCheckBox = New-Object System.Windows.Forms.CheckBox
$apiKeyAuthCheckBox.Text = "使用 API Key 认证"
$apiKeyAuthCheckBox.Location = New-Object System.Drawing.Point(155, 379)
$apiKeyAuthCheckBox.Size = New-Object System.Drawing.Size(180, 24)
$apiKeyAuthCheckBox.Checked = $true
$form.Controls.Add($apiKeyAuthCheckBox)

$apiKeyTextBox = New-Object System.Windows.Forms.TextBox
$apiKeyTextBox.Location = New-Object System.Drawing.Point(30, 406)
$apiKeyTextBox.Size = New-Object System.Drawing.Size(600, 28)
$apiKeyTextBox.UseSystemPasswordChar = $true
$form.Controls.Add($apiKeyTextBox)

$apiKeyHintLabel = New-Object System.Windows.Forms.Label
$apiKeyHintLabel.Text = "留空将保留已有凭据；取消勾选时不发送 Key，但不会删除已保存的 Key。"
$apiKeyHintLabel.Location = New-Object System.Drawing.Point(30, 439)
$apiKeyHintLabel.Size = New-Object System.Drawing.Size(600, 20)
$apiKeyHintLabel.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$form.Controls.Add($apiKeyHintLabel)

$codexLoginButton = New-Object System.Windows.Forms.Button
$codexLoginButton.Text = "登录 Codex"
$codexLoginButton.Location = New-Object System.Drawing.Point(30, 470)
$codexLoginButton.Size = New-Object System.Drawing.Size(125, 32)
$form.Controls.Add($codexLoginButton)

$codexStatusLabel = New-Object System.Windows.Forms.Label
$codexStatusLabel.Text = "Codex 登录由本机 Codex 管理，本程序不读取登录令牌。"
$codexStatusLabel.Location = New-Object System.Drawing.Point(170, 476)
$codexStatusLabel.Size = New-Object System.Drawing.Size(460, 22)
$codexStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
$form.Controls.Add($codexStatusLabel)

$codexImageCheckBox = New-Object System.Windows.Forms.CheckBox
$codexImageCheckBox.Text = "图片生成使用 Codex 订阅（gpt-image-2，文字模型保持当前选择）"
$codexImageCheckBox.Location = New-Object System.Drawing.Point(30, 510)
$codexImageCheckBox.Size = New-Object System.Drawing.Size(600, 24)
$codexImageCheckBox.Checked = $false
$form.Controls.Add($codexImageCheckBox)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "就绪"
$statusLabel.Location = New-Object System.Drawing.Point(30, 545)
$statusLabel.Size = New-Object System.Drawing.Size(600, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$form.Controls.Add($statusLabel)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "保存配置"
$saveButton.Location = New-Object System.Drawing.Point(330, 595)
$saveButton.Size = New-Object System.Drawing.Size(140, 38)
$form.Controls.Add($saveButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "保存并重启 Accio"
$startButton.Location = New-Object System.Drawing.Point(484, 595)
$startButton.Size = New-Object System.Drawing.Size(146, 38)
$startButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.FlatStyle = "Flat"
$form.Controls.Add($startButton)

function Get-SelectedAuthType {
    if ($authComboBox.SelectedIndex -eq 1) {
        return "codex_chatgpt"
    }
    if ($authComboBox.SelectedIndex -eq 2) {
        return "accio_native"
    }
    if ($apiKeyAuthCheckBox.Checked) {
        return "api_key"
    }
    return "none"
}

function Get-ApiProviderFromIndex([int]$index) {
    switch ($index) {
        1 { return $volcengineProvider }
        2 { return $customApiProvider }
        default { return $openCodeProvider }
    }
}

function Get-SelectedApiProvider {
    return (Get-ApiProviderFromIndex $apiProviderComboBox.SelectedIndex)
}

function Get-ApiCredentialTarget([string]$apiProvider) {
    switch ($apiProvider) {
        $volcengineProvider { return $volcengineCredentialTarget }
        $customApiProvider { return $customApiCredentialTarget }
        default { return $openCodeCredentialTarget }
    }
}

function Get-VolcengineReasoningEfforts([string]$model) {
    switch ($model.Trim().ToLowerInvariant()) {
        "deepseek-v4-flash" { return @("default", "disabled", "enabled", "low", "high", "max") }
        "deepseek-v4-pro" { return @("default", "disabled", "enabled", "high", "max") }
        "doubao-seed-2.0-lite" { return @("default", "disabled", "enabled", "low", "medium", "high") }
        "glm-5.3" { return @("default", "low", "high", "max") }
        "glm-5.2" { return @("default", "high", "max") }
        "minimax-m3" { return @("default", "disabled", "enabled") }
        default { return @("default") }
    }
}

function Get-ReasoningEffortDisplayName([string]$reasoningEffort) {
    switch ($reasoningEffort) {
        "default" { return "跟随模型默认" }
        "disabled" { return "关闭" }
        "enabled" { return "开启（默认）" }
        "low" { return "低" }
        "medium" { return "中" }
        "high" { return "高" }
        "max" { return "最高" }
        default { throw "不支持的思考程度：$reasoningEffort" }
    }
}

function Get-ApiProviderSettings([string]$apiProvider) {
    switch ($apiProvider) {
        $volcengineProvider {
            return [pscustomobject]@{
                Endpoint = $volcengineEndpoint
                Model = $script:lastVolcengineModel
                ReasoningEffort = $script:lastVolcengineReasoningEffort
                UseApiKey = $true
            }
        }
        $customApiProvider {
            return [pscustomobject]@{
                Endpoint = $script:lastCustomEndpoint
                Model = $script:lastCustomModel
                ReasoningEffort = $script:lastCustomReasoningEffort
                UseApiKey = $script:lastCustomUseApiKey
            }
        }
        default {
            return [pscustomobject]@{
                Endpoint = $defaultEndpoint
                Model = $script:lastOpenCodeModel
                ReasoningEffort = $script:lastOpenCodeReasoningEffort
                UseApiKey = $script:lastOpenCodeUseApiKey
            }
        }
    }
}

function Get-ApiReasoningEffort([string]$apiProvider) {
    switch ($reasoningEffortComboBox.Text) {
        "跟随模型默认" { return "default" }
        "关闭" { return "disabled" }
        "开启（默认）" { return "enabled" }
        "低" { return "low" }
        "中" { return "medium" }
        "高" { return "high" }
        "高（默认）" { return "high" }
        "最高" { return "max" }
        default { throw "请选择有效的思考程度" }
    }
}

function Get-SelectedApiReasoningEffort {
    return (Get-ApiReasoningEffort (Get-SelectedApiProvider))
}

function Save-ApiProviderControls([string]$apiProvider) {
    $model = $modelComboBox.Text.Trim()
    $reasoningEffort = Get-ApiReasoningEffort $apiProvider
    switch ($apiProvider) {
        $volcengineProvider {
            $script:lastVolcengineModel = $model
            $script:lastVolcengineReasoningEffort = $reasoningEffort
        }
        $customApiProvider {
            $script:lastCustomEndpoint = $endpointTextBox.Text.Trim()
            $script:lastCustomModel = $model
            $script:lastCustomReasoningEffort = $reasoningEffort
            $script:lastCustomUseApiKey = $apiKeyAuthCheckBox.Checked
        }
        default {
            $script:lastOpenCodeModel = $model
            $script:lastOpenCodeReasoningEffort = $reasoningEffort
            $script:lastOpenCodeUseApiKey = $apiKeyAuthCheckBox.Checked
        }
    }
}

function Update-ApiModelOptions([string[]]$models, [string]$selectedModel) {
    $modelComboBox.BeginUpdate()
    try {
        $modelComboBox.Items.Clear()
        foreach ($model in @($models)) {
            [void]$modelComboBox.Items.Add($model)
        }
    } finally {
        $modelComboBox.EndUpdate()
    }
    $modelComboBox.Text = $selectedModel
}

function Get-SelectedReasoningEffort {
    if ($authComboBox.SelectedIndex -eq 0) {
        return (Get-SelectedApiReasoningEffort)
    }
    if ($authComboBox.SelectedIndex -eq 1) {
        return $reasoningEffortComboBox.Text
    }
    return ""
}

function Update-ApiReasoningEfforts([string]$preferredEffort = "high") {
    $reasoningEffortComboBox.BeginUpdate()
    try {
        $reasoningEffortComboBox.Items.Clear()
        $reasoningEfforts = if ((Get-SelectedApiProvider) -eq $volcengineProvider) {
            @(Get-VolcengineReasoningEfforts $modelComboBox.Text)
        } else {
            @("disabled", "low", "high", "max")
        }
        foreach ($reasoningEffort in $reasoningEfforts) {
            [void]$reasoningEffortComboBox.Items.Add((Get-ReasoningEffortDisplayName $reasoningEffort))
        }
        $selectedEffort = if ($reasoningEfforts -contains $preferredEffort) {
            $preferredEffort
        } elseif ($reasoningEfforts -contains "high") {
            "high"
        } elseif ($reasoningEfforts -contains "default") {
            "default"
        } else {
            $reasoningEfforts[0]
        }
        $reasoningEffortComboBox.SelectedItem = Get-ReasoningEffortDisplayName $selectedEffort
    } finally {
        $reasoningEffortComboBox.EndUpdate()
    }
}

function Show-SelectedApiProviderControls {
    $apiProvider = Get-SelectedApiProvider
    $settings = Get-ApiProviderSettings $apiProvider
    $script:updatingApiProvider = $true
    try {
        $endpointTextBox.Text = $settings.Endpoint
        if ($apiProvider -eq $volcengineProvider) {
            Update-ApiModelOptions $volcengineModels $settings.Model
            $apiKeyHintLabel.Text = "留空将保留火山 Coding Plan 已有凭据；该 Key 与 OpenCode Go 完全分开保存。"
        } elseif ($apiProvider -eq $customApiProvider) {
            Update-ApiModelOptions @() $settings.Model
            $apiKeyHintLabel.Text = "留空将保留自定义 API 已有凭据；取消勾选时不发送 Key。"
        } else {
            Update-ApiModelOptions $openCodeModels $settings.Model
            $apiKeyHintLabel.Text = "留空将保留 OpenCode Go 已有凭据；切换火山不会覆盖这个 Key。"
        }
        $apiKeyAuthCheckBox.Checked = [bool]$settings.UseApiKey
        Update-ApiReasoningEfforts $settings.ReasoningEffort
    } finally {
        $script:updatingApiProvider = $false
    }
    $usesApi = $authComboBox.SelectedIndex -eq 0
    $endpointTextBox.Enabled = $usesApi
    $endpointTextBox.ReadOnly = $apiProvider -ne $customApiProvider
    $apiKeyAuthCheckBox.Enabled = $usesApi -and $apiProvider -ne $volcengineProvider
    $apiKeyTextBox.Enabled = $usesApi -and $apiKeyAuthCheckBox.Checked
    $apiKeyLabel.Enabled = $usesApi -and $apiKeyAuthCheckBox.Checked
    $script:previousApiProviderIndex = $apiProviderComboBox.SelectedIndex
}

function Update-NativeReasoningEffort {
    $reasoningEffortComboBox.BeginUpdate()
    try {
        $reasoningEffortComboBox.Items.Clear()
        [void]$reasoningEffortComboBox.Items.Add("由 Accio 官方控制")
        $reasoningEffortComboBox.SelectedIndex = 0
    } finally {
        $reasoningEffortComboBox.EndUpdate()
    }
}

function Update-ReasoningEfforts([string]$preferredEffort = "") {
    $modelId = $modelComboBox.Text
    if ([string]::IsNullOrWhiteSpace($preferredEffort)) {
        $preferredEffort = $reasoningEffortComboBox.Text
    }
    if ([string]::IsNullOrWhiteSpace($preferredEffort)) {
        $preferredEffort = $script:lastCodexReasoningEffort
    }

    $reasoningEffortComboBox.BeginUpdate()
    try {
        $reasoningEffortComboBox.Items.Clear()
        if ($script:codexModelsById.ContainsKey($modelId)) {
            $modelInfo = $script:codexModelsById[$modelId]
            foreach ($effort in @($modelInfo.supportedReasoningEfforts)) {
                [void]$reasoningEffortComboBox.Items.Add([string]$effort)
            }
            if ($reasoningEffortComboBox.Items.Contains($preferredEffort)) {
                $reasoningEffortComboBox.SelectedItem = $preferredEffort
            } elseif ($reasoningEffortComboBox.Items.Contains([string]$modelInfo.defaultReasoningEffort)) {
                $reasoningEffortComboBox.SelectedItem = [string]$modelInfo.defaultReasoningEffort
            } elseif ($reasoningEffortComboBox.Items.Count -gt 0) {
                $reasoningEffortComboBox.SelectedIndex = 0
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($preferredEffort)) {
            [void]$reasoningEffortComboBox.Items.Add($preferredEffort)
            $reasoningEffortComboBox.SelectedItem = $preferredEffort
        }
    } finally {
        $reasoningEffortComboBox.EndUpdate()
    }
    if (-not [string]::IsNullOrWhiteSpace($reasoningEffortComboBox.Text)) {
        $script:lastCodexReasoningEffort = $reasoningEffortComboBox.Text
    }
}

function Update-ModeControls {
    $usesApi = $authComboBox.SelectedIndex -eq 0
    $usesCodex = $authComboBox.SelectedIndex -eq 1
    $usesNative = $authComboBox.SelectedIndex -eq 2

    if ($script:previousAuthIndex -eq 1) {
        $script:lastCodexModel = $modelComboBox.Text
        $script:lastCodexReasoningEffort = $reasoningEffortComboBox.Text
    } elseif ($script:previousAuthIndex -eq 0) {
        $script:lastApiProvider = Get-SelectedApiProvider
        Save-ApiProviderControls $script:lastApiProvider
    }

    if ($usesApi) {
        $providerIndex = switch ($script:lastApiProvider) {
            $volcengineProvider { 1 }
            $customApiProvider { 2 }
            default { 0 }
        }
        if ($apiProviderComboBox.SelectedIndex -ne $providerIndex) {
            $script:updatingApiProvider = $true
            try {
                $apiProviderComboBox.SelectedIndex = $providerIndex
            } finally {
                $script:updatingApiProvider = $false
            }
        }
        Show-SelectedApiProviderControls
    } elseif ($usesCodex) {
        $endpointTextBox.Text = $codexEndpoint
        $modelComboBox.Text = $script:lastCodexModel
        Update-ReasoningEfforts $script:lastCodexReasoningEffort
    } elseif ($usesNative) {
        $endpointTextBox.Text = $nativeEndpoint
        $modelComboBox.Text = $nativeModel
        Update-NativeReasoningEffort
    }

    $endpointTextBox.Enabled = $usesApi
    $endpointLabel.Enabled = $usesApi
    $apiProviderLabel.Enabled = $usesApi
    $apiProviderComboBox.Enabled = $usesApi
    $modelComboBox.Enabled = -not $usesNative
    $modelLabel.Enabled = -not $usesNative
    $apiKeyAuthCheckBox.Enabled = $usesApi -and (Get-SelectedApiProvider) -ne $volcengineProvider
    $apiKeyTextBox.Enabled = $usesApi -and $apiKeyAuthCheckBox.Checked
    $apiKeyLabel.Enabled = $usesApi -and $apiKeyAuthCheckBox.Checked
    $apiKeyHintLabel.Enabled = $usesApi
    $reasoningEffortLabel.Enabled = -not $usesNative
    $reasoningEffortComboBox.Enabled = -not $usesNative
    $codexImageCheckBox.Enabled = -not $usesNative
    $codexRefreshButton.Enabled = $usesCodex -or $codexImageCheckBox.Checked
    $codexLoginButton.Enabled = $usesCodex -or $codexImageCheckBox.Checked
    $script:previousAuthIndex = $authComboBox.SelectedIndex
}

function Refresh-CodexStatus {
    $form.UseWaitCursor = $true
    $codexRefreshButton.Enabled = $false
    $codexStatusLabel.Text = "正在读取本机 Codex 登录和模型..."
    $form.Refresh()
    try {
        $status = Get-CodexStatus
        if ($authComboBox.SelectedIndex -eq 1) {
            $selectedModel = $modelComboBox.Text
            $selectedReasoningEffort = $reasoningEffortComboBox.Text
            $script:codexModelsById.Clear()
            $modelComboBox.BeginUpdate()
            $modelComboBox.Items.Clear()
            foreach ($item in $status.models) {
                [void]$modelComboBox.Items.Add([string]$item.id)
                $script:codexModelsById[[string]$item.id] = $item
            }
            $modelComboBox.EndUpdate()
            if (-not [string]::IsNullOrWhiteSpace($selectedModel) -and $modelComboBox.Items.Contains($selectedModel)) {
                $modelComboBox.SelectedItem = $selectedModel
            } else {
                $default = $status.models | Where-Object { $_.isDefault } | Select-Object -First 1
                if ($default) {
                    $modelComboBox.SelectedItem = [string]$default.id
                } elseif ($modelComboBox.Items.Count -gt 0) {
                    $modelComboBox.SelectedIndex = 0
                }
            }
            Update-ReasoningEfforts $selectedReasoningEffort
        }
        if ($status.authenticated) {
            $imageStatus = if ($status.imageGenerationAvailable) { "，gpt-image-2 可用" } else { "，图片生成不可用" }
            $codexStatusLabel.Text = "已登录 ChatGPT（$($status.planType)），可用模型 $($status.models.Count) 个$imageStatus"
            $codexStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(21, 128, 61)
        } else {
            $codexStatusLabel.Text = "尚未登录 ChatGPT，请点击登录 Codex"
            $codexStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        }
    } finally {
        $form.UseWaitCursor = $false
        $codexRefreshButton.Enabled = $authComboBox.SelectedIndex -eq 1 -or $codexImageCheckBox.Checked
    }
}

function Save-Configuration {
    $apiProvider = $script:lastApiProvider
    if ($authComboBox.SelectedIndex -eq 0) {
        $apiProvider = Get-SelectedApiProvider
        Save-ApiProviderControls $apiProvider
        $script:lastApiProvider = $apiProvider
    }
    $apiSettings = Get-ApiProviderSettings $apiProvider
    $authType = Get-SelectedAuthType
    $reasoningEffort = if ($authType -eq "codex_chatgpt") {
        Get-SelectedReasoningEffort
    } elseif ($authType -eq "accio_native") {
        ""
    } else {
        $apiSettings.ReasoningEffort
    }
    $endpoint = if ($authType -eq "codex_chatgpt") {
        $codexEndpoint
    } elseif ($authType -eq "accio_native") {
        $nativeEndpoint
    } else {
        $apiSettings.Endpoint
    }
    $model = if ($authType -eq "accio_native") {
        $nativeModel
    } elseif ($authType -eq "codex_chatgpt") {
        $modelComboBox.Text.Trim()
    } else {
        $apiSettings.Model
    }
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        throw "API 地址不能为空"
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw "模型名称不能为空"
    }
    if ($authType -ne "codex_chatgpt" -and $authType -ne "accio_native") {
        $uri = $null
        if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or
            ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https")) {
            throw "API 地址必须是完整的 http 或 https 地址"
        }
    }
    if ($authType -eq "codex_chatgpt") {
        $script:lastCodexModel = $model
        $script:lastCodexReasoningEffort = $reasoningEffort
    }
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    [ordered]@{
        endpoint = $endpoint
        model = $model
        reasoningEffort = $reasoningEffort
        authType = $authType
        apiProvider = $apiProvider
        openAiEndpoint = $apiSettings.Endpoint
        openAiModel = $apiSettings.Model
        openAiReasoningEffort = $apiSettings.ReasoningEffort
        openAiUseApiKey = $apiSettings.UseApiKey
        openCodeModel = $script:lastOpenCodeModel
        openCodeReasoningEffort = $script:lastOpenCodeReasoningEffort
        openCodeUseApiKey = $script:lastOpenCodeUseApiKey
        volcengineEndpoint = $volcengineEndpoint
        volcengineModel = $script:lastVolcengineModel
        volcengineReasoningEffort = $script:lastVolcengineReasoningEffort
        customEndpoint = $script:lastCustomEndpoint
        customModel = $script:lastCustomModel
        customReasoningEffort = $script:lastCustomReasoningEffort
        customUseApiKey = $script:lastCustomUseApiKey
        codexModel = $script:lastCodexModel
        codexReasoningEffort = $script:lastCodexReasoningEffort
        codexImageEnabled = [bool]$codexImageCheckBox.Checked
    } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    if ($authType -eq "api_key" -and -not [string]::IsNullOrWhiteSpace($apiKeyTextBox.Text)) {
        [AccioModelApiAuth.NativeCredential]::Write((Get-ApiCredentialTarget $apiProvider), $apiKeyTextBox.Text)
        $apiKeyTextBox.Clear()
    }
}

function Show-ConfigurationError([string]$message) {
    $statusLabel.Text = "操作失败"
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        "Accio 模型接入配置",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

$authComboBox.Add_SelectedIndexChanged({
    Update-ModeControls
})

$codexImageCheckBox.Add_CheckedChanged({
    Update-ModeControls
})

$apiProviderComboBox.Add_SelectedIndexChanged({
    if ($script:updatingApiProvider -or $authComboBox.SelectedIndex -ne 0) {
        return
    }
    if ($script:previousApiProviderIndex -ge 0) {
        Save-ApiProviderControls (Get-ApiProviderFromIndex $script:previousApiProviderIndex)
    }
    $script:lastApiProvider = Get-SelectedApiProvider
    $apiKeyTextBox.Clear()
    Show-SelectedApiProviderControls
})

$apiKeyAuthCheckBox.Add_CheckedChanged({
    if ($script:updatingApiProvider) {
        return
    }
    $usesApiKey = $authComboBox.SelectedIndex -eq 0 -and $apiKeyAuthCheckBox.Checked
    $apiKeyTextBox.Enabled = $usesApiKey
    $apiKeyLabel.Enabled = $usesApiKey
})

$modelComboBox.Add_SelectedIndexChanged({
    if ($authComboBox.SelectedIndex -eq 1) {
        Update-ReasoningEfforts
    } elseif (-not $script:updatingApiProvider -and
        $authComboBox.SelectedIndex -eq 0 -and
        (Get-SelectedApiProvider) -eq $volcengineProvider) {
        Update-ApiReasoningEfforts (Get-SelectedApiReasoningEffort)
    }
})

$codexRefreshButton.Add_Click({
    try {
        Refresh-CodexStatus
    } catch {
        Show-ConfigurationError $_.Exception.Message
    }
})

$codexLoginButton.Add_Click({
    try {
        $codexExe = Get-CodexExecutable
        Start-Process -FilePath $codexExe -ArgumentList "login"
        $codexStatusLabel.Text = "已启动 Codex 登录；在浏览器完成后点击刷新 Codex 登录和模型"
        $codexStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    } catch {
        Show-ConfigurationError $_.Exception.Message
    }
})

$saveButton.Add_Click({
    try {
        Save-Configuration
        $statusLabel.Text = "配置已保存到 $configPath"
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(21, 128, 61)
    } catch {
        Show-ConfigurationError $_.Exception.Message
    }
})

$startButton.Add_Click({
    try {
        if (Get-Process -Name "Accio" -ErrorAction SilentlyContinue) {
            $modeName = if ((Get-SelectedAuthType) -eq "accio_native") { "Accio 官方原生认证" } else { "当前自定义模型认证" }
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "应用 $modeName 需要重启 Accio。正在运行的任务或未发送内容可能丢失。是否继续？",
                "确认重启 Accio",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                return
            }
        }
        Save-Configuration
        $statusLabel.Text = "正在应用配置并启动 Accio..."
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $form.Refresh()
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcherPath -RestartBridge -RestartAccio 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String)
        }
        $statusLabel.Text = if ((Get-SelectedAuthType) -eq "accio_native") { "Accio 已恢复官方原生认证" } else { "Accio 已使用当前模型配置启动" }
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(21, 128, 61)
    } catch {
        Show-ConfigurationError $_.Exception.Message
    }
})

if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $legacyApiEndpoint = ""
    if ($null -ne $config.PSObject.Properties["openAiEndpoint"]) {
        $legacyApiEndpoint = [string]$config.openAiEndpoint
    } elseif ([string]$config.authType -eq "api_key" -or [string]$config.authType -eq "none") {
        $legacyApiEndpoint = [string]$config.endpoint
    }
    $legacyApiModel = ""
    if ($null -ne $config.PSObject.Properties["openAiModel"]) {
        $legacyApiModel = [string]$config.openAiModel
    } elseif ([string]$config.authType -eq "api_key" -or [string]$config.authType -eq "none") {
        $legacyApiModel = [string]$config.model
    }
    $legacyApiReasoningEffort = "high"
    if ($null -ne $config.PSObject.Properties["openAiReasoningEffort"]) {
        $legacyApiReasoningEffort = [string]$config.openAiReasoningEffort
    } elseif (([string]$config.authType -eq "api_key" -or [string]$config.authType -eq "none") -and
        $null -ne $config.PSObject.Properties["reasoningEffort"] -and
        -not [string]::IsNullOrWhiteSpace([string]$config.reasoningEffort)) {
        $legacyApiReasoningEffort = [string]$config.reasoningEffort
    }
    $legacyApiUseApiKey = [string]$config.authType -ne "none"
    if ($null -ne $config.PSObject.Properties["openAiUseApiKey"]) {
        $legacyApiUseApiKey = [bool]$config.openAiUseApiKey
    }

    if ($null -ne $config.PSObject.Properties["apiProvider"] -and
        -not [string]::IsNullOrWhiteSpace([string]$config.apiProvider)) {
        $lastApiProvider = [string]$config.apiProvider
    } elseif ($legacyApiEndpoint.StartsWith("https://ark.cn-beijing.volces.com/api/coding/v3", [StringComparison]::OrdinalIgnoreCase)) {
        $lastApiProvider = $volcengineProvider
    } elseif ([string]::Equals($legacyApiEndpoint, $defaultEndpoint, [StringComparison]::OrdinalIgnoreCase)) {
        $lastApiProvider = $openCodeProvider
    } else {
        $lastApiProvider = $customApiProvider
    }
    if ($lastApiProvider -ne $openCodeProvider -and
        $lastApiProvider -ne $volcengineProvider -and
        $lastApiProvider -ne $customApiProvider) {
        $lastApiProvider = $customApiProvider
    }

    if ($null -ne $config.PSObject.Properties["openCodeModel"]) {
        $lastOpenCodeModel = [string]$config.openCodeModel
    }
    if ($null -ne $config.PSObject.Properties["openCodeReasoningEffort"]) {
        $lastOpenCodeReasoningEffort = [string]$config.openCodeReasoningEffort
    }
    if ($null -ne $config.PSObject.Properties["openCodeUseApiKey"]) {
        $lastOpenCodeUseApiKey = [bool]$config.openCodeUseApiKey
    }
    if ($null -ne $config.PSObject.Properties["volcengineModel"]) {
        $lastVolcengineModel = [string]$config.volcengineModel
    }
    if ($null -ne $config.PSObject.Properties["volcengineReasoningEffort"]) {
        $lastVolcengineReasoningEffort = [string]$config.volcengineReasoningEffort
    }
    if ($null -ne $config.PSObject.Properties["customEndpoint"]) {
        $lastCustomEndpoint = [string]$config.customEndpoint
    }
    if ($null -ne $config.PSObject.Properties["customModel"]) {
        $lastCustomModel = [string]$config.customModel
    }
    if ($null -ne $config.PSObject.Properties["customReasoningEffort"]) {
        $lastCustomReasoningEffort = [string]$config.customReasoningEffort
    }
    if ($null -ne $config.PSObject.Properties["customUseApiKey"]) {
        $lastCustomUseApiKey = [bool]$config.customUseApiKey
    }

    if ($lastApiProvider -eq $openCodeProvider -and $null -eq $config.PSObject.Properties["openCodeModel"]) {
        if (-not [string]::IsNullOrWhiteSpace($legacyApiModel)) {
            $lastOpenCodeModel = $legacyApiModel
        }
        $lastOpenCodeReasoningEffort = $legacyApiReasoningEffort
        $lastOpenCodeUseApiKey = $legacyApiUseApiKey
    } elseif ($lastApiProvider -eq $volcengineProvider -and $null -eq $config.PSObject.Properties["volcengineModel"]) {
        if (-not [string]::IsNullOrWhiteSpace($legacyApiModel)) {
            $lastVolcengineModel = $legacyApiModel
        }
        if (@("default", "enabled", "disabled", "low", "medium", "high", "max") -contains $legacyApiReasoningEffort) {
            $lastVolcengineReasoningEffort = $legacyApiReasoningEffort
        }
    } elseif ($lastApiProvider -eq $customApiProvider -and $null -eq $config.PSObject.Properties["customEndpoint"]) {
        $lastCustomEndpoint = $legacyApiEndpoint
        $lastCustomModel = $legacyApiModel
        $lastCustomReasoningEffort = $legacyApiReasoningEffort
        $lastCustomUseApiKey = $legacyApiUseApiKey
    }

    if ($null -ne $config.PSObject.Properties["codexModel"]) {
        $lastCodexModel = [string]$config.codexModel
    } elseif ([string]$config.authType -eq "codex_chatgpt") {
        $lastCodexModel = [string]$config.model
    }
    if ($null -ne $config.PSObject.Properties["codexReasoningEffort"]) {
        $lastCodexReasoningEffort = [string]$config.codexReasoningEffort
    } elseif ([string]$config.authType -eq "codex_chatgpt" -and $null -ne $config.PSObject.Properties["reasoningEffort"]) {
        $lastCodexReasoningEffort = [string]$config.reasoningEffort
    }
    if ($null -ne $config.PSObject.Properties["codexImageEnabled"]) {
        $codexImageEnabled = [bool]$config.codexImageEnabled
    }

    $apiProviderComboBox.SelectedIndex = switch ($lastApiProvider) {
        $volcengineProvider { 1 }
        $customApiProvider { 2 }
        default { 0 }
    }
    if ([string]$config.authType -eq "api_key" -or [string]$config.authType -eq "none") {
        $authComboBox.SelectedIndex = 0
    } elseif ([string]$config.authType -eq "codex_chatgpt") {
        $authComboBox.SelectedIndex = 1
    } elseif ([string]$config.authType -eq "accio_native") {
        $authComboBox.SelectedIndex = 2
    } else {
        $authComboBox.SelectedIndex = 0
    }
    $codexImageCheckBox.Checked = $codexImageEnabled
} else {
    $apiProviderComboBox.SelectedIndex = 0
    $authComboBox.SelectedIndex = 0
}
Update-ModeControls

$form.Add_Shown({
    if ($authComboBox.SelectedIndex -eq 1 -or $codexImageCheckBox.Checked) {
        try {
            Refresh-CodexStatus
        } catch {
            Show-ConfigurationError $_.Exception.Message
        }
    }
})

[void]$form.ShowDialog()
