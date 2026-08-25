Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$credentialTarget = "AccioOpenCodeGoApiKey"
$configDirectory = Join-Path $env:LOCALAPPDATA "AccioModelApiAuth"
$configPath = Join-Path $configDirectory "config.json"
$launcherPath = Join-Path $PSScriptRoot "accio_opencode_launcher.ps1"
$codexStatusScript = Join-Path $PSScriptRoot "accio_codex_status.js"
$nodeExe = "C:\Program Files\nodejs\node.exe"
$defaultEndpoint = "https://opencode.ai/zen/go/v1/chat/completions"
$codexEndpoint = "codex-app-server://local"
$defaultModel = "deepseek-v4-flash"
$defaultCodexModel = "gpt-5.6-sol"
$lastApiEndpoint = $defaultEndpoint
$lastApiModel = $defaultModel
$lastCodexModel = $defaultCodexModel
$lastCodexReasoningEffort = ""
$codexModelsById = @{}
$previousAuthIndex = -1

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
$form.Text = "Accio 模型 API 与 Codex 登录配置"
$form.ClientSize = New-Object System.Drawing.Size(660, 550)
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
$titleLabel.Text = "Accio 模型认证配置"
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
$authLabel.Text = "认证方式"
$authLabel.Location = New-Object System.Drawing.Point(30, 105)
$authLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($authLabel)

$authComboBox = New-Object System.Windows.Forms.ComboBox
$authComboBox.Location = New-Object System.Drawing.Point(30, 130)
$authComboBox.Size = New-Object System.Drawing.Size(600, 28)
$authComboBox.DropDownStyle = "DropDownList"
[void]$authComboBox.Items.Add("API Key（OpenAI-compatible，保存到 Windows 凭据管理器）")
[void]$authComboBox.Items.Add("无需认证（本地 OpenAI-compatible 服务）")
[void]$authComboBox.Items.Add("Codex ChatGPT 登录（由本机 Codex 托管）")
$form.Controls.Add($authComboBox)

$endpointLabel = New-Object System.Windows.Forms.Label
$endpointLabel.Text = "API 地址"
$endpointLabel.Location = New-Object System.Drawing.Point(30, 174)
$endpointLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($endpointLabel)

$endpointTextBox = New-Object System.Windows.Forms.TextBox
$endpointTextBox.Location = New-Object System.Drawing.Point(30, 199)
$endpointTextBox.Size = New-Object System.Drawing.Size(600, 28)
$form.Controls.Add($endpointTextBox)

$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = "模型名称"
$modelLabel.Location = New-Object System.Drawing.Point(30, 245)
$modelLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($modelLabel)

$modelComboBox = New-Object System.Windows.Forms.ComboBox
$modelComboBox.Location = New-Object System.Drawing.Point(30, 270)
$modelComboBox.Size = New-Object System.Drawing.Size(255, 28)
$modelComboBox.DropDownStyle = "DropDown"
$modelComboBox.AutoCompleteMode = "SuggestAppend"
$modelComboBox.AutoCompleteSource = "ListItems"
$form.Controls.Add($modelComboBox)

$reasoningEffortLabel = New-Object System.Windows.Forms.Label
$reasoningEffortLabel.Text = "思考强度"
$reasoningEffortLabel.Location = New-Object System.Drawing.Point(300, 245)
$reasoningEffortLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($reasoningEffortLabel)

$reasoningEffortComboBox = New-Object System.Windows.Forms.ComboBox
$reasoningEffortComboBox.Location = New-Object System.Drawing.Point(300, 270)
$reasoningEffortComboBox.Size = New-Object System.Drawing.Size(120, 28)
$reasoningEffortComboBox.DropDownStyle = "DropDownList"
$form.Controls.Add($reasoningEffortComboBox)

$codexRefreshButton = New-Object System.Windows.Forms.Button
$codexRefreshButton.Text = "刷新 Codex 登录和模型"
$codexRefreshButton.Location = New-Object System.Drawing.Point(434, 269)
$codexRefreshButton.Size = New-Object System.Drawing.Size(196, 30)
$form.Controls.Add($codexRefreshButton)

$apiKeyLabel = New-Object System.Windows.Forms.Label
$apiKeyLabel.Text = "API Key"
$apiKeyLabel.Location = New-Object System.Drawing.Point(30, 316)
$apiKeyLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($apiKeyLabel)

$apiKeyTextBox = New-Object System.Windows.Forms.TextBox
$apiKeyTextBox.Location = New-Object System.Drawing.Point(30, 341)
$apiKeyTextBox.Size = New-Object System.Drawing.Size(600, 28)
$apiKeyTextBox.UseSystemPasswordChar = $true
$form.Controls.Add($apiKeyTextBox)

$apiKeyHintLabel = New-Object System.Windows.Forms.Label
$apiKeyHintLabel.Text = "留空将保留已有凭据；Key 不会写入 config.json 或 Git 仓库。"
$apiKeyHintLabel.Location = New-Object System.Drawing.Point(30, 374)
$apiKeyHintLabel.Size = New-Object System.Drawing.Size(600, 20)
$apiKeyHintLabel.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$form.Controls.Add($apiKeyHintLabel)

$codexLoginButton = New-Object System.Windows.Forms.Button
$codexLoginButton.Text = "登录 Codex"
$codexLoginButton.Location = New-Object System.Drawing.Point(30, 405)
$codexLoginButton.Size = New-Object System.Drawing.Size(125, 32)
$form.Controls.Add($codexLoginButton)

$codexStatusLabel = New-Object System.Windows.Forms.Label
$codexStatusLabel.Text = "Codex 登录由本机 Codex 管理，本程序不读取登录令牌。"
$codexStatusLabel.Location = New-Object System.Drawing.Point(170, 411)
$codexStatusLabel.Size = New-Object System.Drawing.Size(460, 22)
$codexStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
$form.Controls.Add($codexStatusLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "就绪"
$statusLabel.Location = New-Object System.Drawing.Point(30, 450)
$statusLabel.Size = New-Object System.Drawing.Size(600, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$form.Controls.Add($statusLabel)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "保存配置"
$saveButton.Location = New-Object System.Drawing.Point(330, 495)
$saveButton.Size = New-Object System.Drawing.Size(140, 38)
$form.Controls.Add($saveButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "保存并启动 Accio"
$startButton.Location = New-Object System.Drawing.Point(484, 495)
$startButton.Size = New-Object System.Drawing.Size(146, 38)
$startButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.FlatStyle = "Flat"
$form.Controls.Add($startButton)

function Get-SelectedAuthType {
    if ($authComboBox.SelectedIndex -eq 1) {
        return "none"
    }
    if ($authComboBox.SelectedIndex -eq 2) {
        return "codex_chatgpt"
    }
    return "api_key"
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
    $usesCodex = $authComboBox.SelectedIndex -eq 2
    $usesApiKey = $authComboBox.SelectedIndex -eq 0
    if ($usesCodex) {
        if ($script:previousAuthIndex -ne 2 -and $endpointTextBox.Text -ne $codexEndpoint) {
            $script:lastApiEndpoint = $endpointTextBox.Text
            $script:lastApiModel = $modelComboBox.Text
        }
        $endpointTextBox.Text = $codexEndpoint
        $modelComboBox.Text = $script:lastCodexModel
        Update-ReasoningEfforts $script:lastCodexReasoningEffort
    } elseif ($script:previousAuthIndex -eq 2) {
        $script:lastCodexModel = $modelComboBox.Text
        $script:lastCodexReasoningEffort = $reasoningEffortComboBox.Text
        $endpointTextBox.Text = $script:lastApiEndpoint
        $modelComboBox.Text = $script:lastApiModel
    }
    $endpointTextBox.Enabled = -not $usesCodex
    $endpointLabel.Enabled = -not $usesCodex
    $apiKeyTextBox.Enabled = $usesApiKey
    $apiKeyLabel.Enabled = $usesApiKey
    $apiKeyHintLabel.Enabled = $usesApiKey
    $reasoningEffortLabel.Enabled = $usesCodex
    $reasoningEffortComboBox.Enabled = $usesCodex
    $codexRefreshButton.Enabled = $usesCodex
    $codexLoginButton.Enabled = $usesCodex
    $script:previousAuthIndex = $authComboBox.SelectedIndex
}

function Refresh-CodexStatus {
    $form.UseWaitCursor = $true
    $codexRefreshButton.Enabled = $false
    $codexStatusLabel.Text = "正在读取本机 Codex 登录和模型..."
    $form.Refresh()
    try {
        $status = Get-CodexStatus
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
        if ($status.authenticated) {
            $codexStatusLabel.Text = "已登录 ChatGPT（$($status.planType)），可用模型 $($status.models.Count) 个"
            $codexStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(21, 128, 61)
        } else {
            $codexStatusLabel.Text = "尚未登录 ChatGPT，请点击登录 Codex"
            $codexStatusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        }
    } finally {
        $form.UseWaitCursor = $false
        $codexRefreshButton.Enabled = $authComboBox.SelectedIndex -eq 2
    }
}

function Save-Configuration {
    $authType = Get-SelectedAuthType
    $endpoint = if ($authType -eq "codex_chatgpt") { $codexEndpoint } else { $endpointTextBox.Text.Trim() }
    $model = $modelComboBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        throw "API 地址不能为空"
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw "模型名称不能为空"
    }
    if ($authType -ne "codex_chatgpt") {
        $uri = $null
        if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or
            ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https")) {
            throw "API 地址必须是完整的 http 或 https 地址"
        }
    }
    if ($authType -eq "codex_chatgpt") {
        $script:lastCodexModel = $model
        $script:lastCodexReasoningEffort = $reasoningEffortComboBox.Text
    } else {
        $script:lastApiEndpoint = $endpoint
        $script:lastApiModel = $model
    }
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    [ordered]@{
        endpoint = $endpoint
        model = $model
        reasoningEffort = if ($authType -eq "codex_chatgpt") { $script:lastCodexReasoningEffort } else { "" }
        authType = $authType
        openAiEndpoint = $script:lastApiEndpoint
        openAiModel = $script:lastApiModel
        codexModel = $script:lastCodexModel
        codexReasoningEffort = $script:lastCodexReasoningEffort
    } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
    if ($authType -eq "api_key" -and -not [string]::IsNullOrWhiteSpace($apiKeyTextBox.Text)) {
        [AccioModelApiAuth.NativeCredential]::Write($credentialTarget, $apiKeyTextBox.Text)
        $apiKeyTextBox.Clear()
    }
}

function Show-ConfigurationError([string]$message) {
    $statusLabel.Text = "操作失败"
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        "Accio 模型认证配置",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

$authComboBox.Add_SelectedIndexChanged({
    Update-ModeControls
})

$modelComboBox.Add_SelectedIndexChanged({
    if ($authComboBox.SelectedIndex -eq 2) {
        Update-ReasoningEfforts
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
        Save-Configuration
        $statusLabel.Text = "正在应用配置并启动 Accio..."
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $form.Refresh()
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcherPath -RestartBridge 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output | Out-String)
        }
        $statusLabel.Text = "Accio 已使用当前模型配置启动"
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(21, 128, 61)
    } catch {
        Show-ConfigurationError $_.Exception.Message
    }
})

if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($null -ne $config.PSObject.Properties["openAiEndpoint"]) {
        $lastApiEndpoint = [string]$config.openAiEndpoint
    } elseif ([string]$config.authType -ne "codex_chatgpt") {
        $lastApiEndpoint = [string]$config.endpoint
    }
    if ($null -ne $config.PSObject.Properties["openAiModel"]) {
        $lastApiModel = [string]$config.openAiModel
    } elseif ([string]$config.authType -ne "codex_chatgpt") {
        $lastApiModel = [string]$config.model
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
    $endpointTextBox.Text = [string]$config.endpoint
    $modelComboBox.Text = [string]$config.model
    if ([string]$config.authType -eq "none") {
        $authComboBox.SelectedIndex = 1
    } elseif ([string]$config.authType -eq "codex_chatgpt") {
        $authComboBox.SelectedIndex = 2
    } else {
        $authComboBox.SelectedIndex = 0
    }
} else {
    $endpointTextBox.Text = $defaultEndpoint
    $modelComboBox.Text = $defaultModel
    $authComboBox.SelectedIndex = 0
}
Update-ModeControls

$form.Add_Shown({
    if ($authComboBox.SelectedIndex -eq 2) {
        try {
            Refresh-CodexStatus
        } catch {
            Show-ConfigurationError $_.Exception.Message
        }
    }
})

[void]$form.ShowDialog()
