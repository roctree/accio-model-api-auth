Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$credentialTarget = "AccioOpenCodeGoApiKey"
$configDirectory = Join-Path $env:LOCALAPPDATA "AccioModelApiAuth"
$configPath = Join-Path $configDirectory "config.json"
$launcherPath = Join-Path $PSScriptRoot "accio_opencode_launcher.ps1"
$defaultEndpoint = "https://opencode.ai/zen/go/v1/chat/completions"
$defaultModel = "deepseek-v4-flash"

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

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Accio 模型 API 配置"
$form.ClientSize = New-Object System.Drawing.Size(660, 455)
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
$titleLabel.Text = "Accio 模型 API 配置"
$titleLabel.Location = New-Object System.Drawing.Point(28, 17)
$titleLabel.Size = New-Object System.Drawing.Size(500, 30)
$titleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::White
$headerPanel.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "配置模型服务，不改变 Accio 的历史会话、Skill、MCP 和工具路由"
$subtitleLabel.Location = New-Object System.Drawing.Point(30, 50)
$subtitleLabel.Size = New-Object System.Drawing.Size(590, 20)
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
$headerPanel.Controls.Add($subtitleLabel)

$endpointLabel = New-Object System.Windows.Forms.Label
$endpointLabel.Text = "API 地址"
$endpointLabel.Location = New-Object System.Drawing.Point(30, 105)
$endpointLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($endpointLabel)

$endpointTextBox = New-Object System.Windows.Forms.TextBox
$endpointTextBox.Location = New-Object System.Drawing.Point(30, 130)
$endpointTextBox.Size = New-Object System.Drawing.Size(600, 28)
$form.Controls.Add($endpointTextBox)

$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = "模型名称"
$modelLabel.Location = New-Object System.Drawing.Point(30, 174)
$modelLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($modelLabel)

$modelTextBox = New-Object System.Windows.Forms.TextBox
$modelTextBox.Location = New-Object System.Drawing.Point(30, 199)
$modelTextBox.Size = New-Object System.Drawing.Size(286, 28)
$form.Controls.Add($modelTextBox)

$authLabel = New-Object System.Windows.Forms.Label
$authLabel.Text = "认证方式"
$authLabel.Location = New-Object System.Drawing.Point(344, 174)
$authLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($authLabel)

$authComboBox = New-Object System.Windows.Forms.ComboBox
$authComboBox.Location = New-Object System.Drawing.Point(344, 199)
$authComboBox.Size = New-Object System.Drawing.Size(286, 28)
$authComboBox.DropDownStyle = "DropDownList"
[void]$authComboBox.Items.Add("API Key（Windows 凭据管理器）")
[void]$authComboBox.Items.Add("无需认证（本地模型服务）")
$form.Controls.Add($authComboBox)

$apiKeyLabel = New-Object System.Windows.Forms.Label
$apiKeyLabel.Text = "API Key"
$apiKeyLabel.Location = New-Object System.Drawing.Point(30, 245)
$apiKeyLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($apiKeyLabel)

$apiKeyTextBox = New-Object System.Windows.Forms.TextBox
$apiKeyTextBox.Location = New-Object System.Drawing.Point(30, 270)
$apiKeyTextBox.Size = New-Object System.Drawing.Size(600, 28)
$apiKeyTextBox.UseSystemPasswordChar = $true
$form.Controls.Add($apiKeyTextBox)

$apiKeyHintLabel = New-Object System.Windows.Forms.Label
$apiKeyHintLabel.Text = "留空将保留已有凭据；Key 不会写入 config.json 或 Git 仓库。"
$apiKeyHintLabel.Location = New-Object System.Drawing.Point(30, 303)
$apiKeyHintLabel.Size = New-Object System.Drawing.Size(600, 20)
$apiKeyHintLabel.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$form.Controls.Add($apiKeyHintLabel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "就绪"
$statusLabel.Location = New-Object System.Drawing.Point(30, 343)
$statusLabel.Size = New-Object System.Drawing.Size(600, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$form.Controls.Add($statusLabel)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "保存配置"
$saveButton.Location = New-Object System.Drawing.Point(330, 390)
$saveButton.Size = New-Object System.Drawing.Size(140, 38)
$form.Controls.Add($saveButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "保存并启动 Accio"
$startButton.Location = New-Object System.Drawing.Point(484, 390)
$startButton.Size = New-Object System.Drawing.Size(146, 38)
$startButton.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.FlatStyle = "Flat"
$form.Controls.Add($startButton)

function Get-SelectedAuthType {
    if ($authComboBox.SelectedIndex -eq 1) {
        return "none"
    }
    return "api_key"
}

function Save-Configuration {
    $endpoint = $endpointTextBox.Text.Trim()
    $model = $modelTextBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        throw "API 地址不能为空"
    }
    if ([string]::IsNullOrWhiteSpace($model)) {
        throw "模型名称不能为空"
    }
    $uri = $null
    if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or
        ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https")) {
        throw "API 地址必须是完整的 http 或 https 地址"
    }
    $authType = Get-SelectedAuthType
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    [ordered]@{
        endpoint = $endpoint
        model = $model
        authType = $authType
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
        "Accio 模型 API 配置",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

$authComboBox.Add_SelectedIndexChanged({
    $usesApiKey = $authComboBox.SelectedIndex -eq 0
    $apiKeyTextBox.Enabled = $usesApiKey
    $apiKeyLabel.Enabled = $usesApiKey
    $apiKeyHintLabel.Enabled = $usesApiKey
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
    $endpointTextBox.Text = [string]$config.endpoint
    $modelTextBox.Text = [string]$config.model
    if ([string]$config.authType -eq "none") {
        $authComboBox.SelectedIndex = 1
    } else {
        $authComboBox.SelectedIndex = 0
    }
} else {
    $endpointTextBox.Text = $defaultEndpoint
    $modelTextBox.Text = $defaultModel
    $authComboBox.SelectedIndex = 0
}

[void]$form.ShowDialog()
