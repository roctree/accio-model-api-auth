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
$volcenginePresetModels = @(
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
$volcengineModels = @($volcenginePresetModels)
$volcengineLiveModels = @()
$volcengineLiveModelsUpdatedAt = ""
$arkCliRefreshIntervalMs = 300000
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
$formShown = $false
$volcengineRefreshing = $false
$codexRefreshing = $false
$volcengineRefreshPowerShell = $null
$volcengineRefreshAsyncResult = $null
$codexRefreshPowerShell = $null
$codexRefreshAsyncResult = $null
$volcengineStatusText = "等待读取火山 Coding Plan 状态..."
$volcengineStatusLevel = "idle"
$volcengineStatusToolTip = ""
$codexStatusText = "等待读取 Codex 登录、额度和模型..."
$codexStatusLevel = "idle"
$codexStatusToolTip = ""

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

function Get-JsonPropertyValue($object, [string]$name, $defaultValue = $null) {
    if ($null -eq $object) {
        return $defaultValue
    }
    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) {
        return $defaultValue
    }
    return $property.Value
}

function Get-ArkCliScript {
    $command = Get-Command arkcli.ps1 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command arkcli -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $command -or [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        throw "未安装火山官方 Ark CLI。请先执行：npm install -g @volcengine/ark-cli@latest"
    }
    return [string]$command.Source
}

function Invoke-ArkCliJson([string]$skillName, [string[]]$arguments) {
    $arkCliScript = Get-ArkCliScript
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $environmentNames = @(
        "ARKCLI_NO_UPDATE_NOTIFIER",
        "ARKCLI_CALLER_TYPE",
        "ARKCLI_CALLER_NAME",
        "ARKCLI_SKILL_NAME"
    )
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    try {
        $env:ARKCLI_NO_UPDATE_NOTIFIER = "1"
        $env:ARKCLI_CALLER_TYPE = "ai_agent"
        $env:ARKCLI_CALLER_NAME = "accio-model-api-auth"
        $env:ARKCLI_SKILL_NAME = $skillName
        $output = & $arkCliScript @arguments 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stdout = (@($output) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $stderr = ""
        if (Test-Path -LiteralPath $stderrPath) {
            $stderrContent = Get-Content -LiteralPath $stderrPath -Raw
            if ($null -ne $stderrContent) {
                $stderr = $stderrContent.Trim()
            }
        }
        if ($exitCode -ne 0) {
            $message = if (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr } else { $stdout.Trim() }
            throw "Ark CLI 命令失败（退出码 $exitCode）：$message"
        }
        if ([string]::IsNullOrWhiteSpace($stdout)) {
            throw "Ark CLI 没有返回 JSON 数据"
        }
        try {
            return ($stdout | ConvertFrom-Json)
        } catch {
            throw "Ark CLI 返回的不是有效 JSON：$stdout"
        }
    } finally {
        foreach ($name in $environmentNames) {
            $previousValue = $previousEnvironment[$name]
            if ($null -eq $previousValue) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            } else {
                Set-Item -LiteralPath "Env:$name" -Value $previousValue
            }
        }
        Remove-Item -LiteralPath $stderrPath -ErrorAction SilentlyContinue
    }
}

function Get-ArkCliVersion {
    $arkCliScript = Get-ArkCliScript
    $output = & $arkCliScript --version 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "无法读取 Ark CLI 版本"
    }
    return ((@($output) | ForEach-Object { [string]$_ }) -join " ").Trim()
}

function Get-VolcengineDashboardData {
    $auth = Invoke-ArkCliJson "arkcli-auth" @("auth", "status", "--format", "json")
    $loggedIn = [bool](Get-JsonPropertyValue $auth "logged_in" $false)
    if (-not $loggedIn) {
        return [pscustomobject]@{
            CliVersion = Get-ArkCliVersion
            LoggedIn = $false
            Auth = $auth
            Plans = @()
            UsageItems = @()
            Viewer = $null
            Models = @()
            LiveModelIds = @()
            Errors = @()
            RefreshedAt = Get-Date
        }
    }

    $plansResponse = Invoke-ArkCliJson "arkcli-plans" @("plans", "get", "--format", "json")
    $allPlans = @(Get-JsonPropertyValue $plansResponse "plans" @())
    $codingPlans = @($allPlans | Where-Object {
        $key = [string](Get-JsonPropertyValue $_ "key" "")
        $key -eq "coding-plan" -or $key -eq "coding-plan-team"
    })

    $usageItems = @()
    $viewer = $null
    $queryErrors = @()
    try {
        $usageResponse = Invoke-ArkCliJson "arkcli-usage" @("usage", "plan", "--format", "json")
        $usageItems = @(Get-JsonPropertyValue $usageResponse "items" @()) | Where-Object {
            $product = [string](Get-JsonPropertyValue $_ "product" "")
            $product -eq "coding-plan" -or $product -eq "coding-plan-team"
        }
        $viewer = Get-JsonPropertyValue $usageResponse "viewer" $null
    } catch {
        $queryErrors += "套餐用量：$($_.Exception.Message)"
    }

    $modelRows = @()
    $modelIds = New-Object System.Collections.Generic.List[string]
    $modelErrors = @()
    foreach ($plan in $codingPlans) {
        $planKey = [string](Get-JsonPropertyValue $plan "key" "")
        try {
            $modelResponse = Invoke-ArkCliJson "arkcli-plans" @("plans", "model-list", "--plan", $planKey, "--format", "json")
            $selectedModelId = [string](Get-JsonPropertyValue $modelResponse "selected_model_id" "")
            $legacyLatestModelId = [string](Get-JsonPropertyValue $modelResponse "ark_latest_model_id" "")
            if ([string]::IsNullOrWhiteSpace($selectedModelId)) {
                $selectedModelId = $legacyLatestModelId
            }
            foreach ($model in @(Get-JsonPropertyValue $modelResponse "models" @())) {
                $modelId = [string](Get-JsonPropertyValue $model "model_id" "")
                $outputName = [string](Get-JsonPropertyValue $model "output_name" "")
                $configuredModelName = if (-not [string]::IsNullOrWhiteSpace($outputName)) { $outputName } else { $modelId }
                if ([string]::IsNullOrWhiteSpace($configuredModelName)) {
                    continue
                }
                $legacyIsLatest = [bool](Get-JsonPropertyValue $model "is_ark_latest" $false)
                $isSelected = [bool](Get-JsonPropertyValue $model "selected" $legacyIsLatest)
                if (-not $isSelected -and -not [string]::IsNullOrWhiteSpace($selectedModelId)) {
                    $isSelected = $modelId -eq $selectedModelId
                }
                $note = if ($isSelected) { "当前套餐选中模型" } else { "" }
                $modelRows += [pscustomobject]@{
                    Plan = $planKey
                    ModelId = $configuredModelName
                    Note = $note
                }
                if (-not $modelIds.Contains($configuredModelName)) {
                    [void]$modelIds.Add($configuredModelName)
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($legacyLatestModelId)) {
                $modelRows += [pscustomobject]@{
                    Plan = $planKey
                    ModelId = "ark-code-latest"
                    Note = "别名 -> $legacyLatestModelId"
                }
                if (-not $modelIds.Contains("ark-code-latest")) {
                    [void]$modelIds.Add("ark-code-latest")
                }
            }
        } catch {
            $modelErrors += "${planKey}：$($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        CliVersion = Get-ArkCliVersion
        LoggedIn = $true
        Auth = $auth
        Plans = @($codingPlans)
        UsageItems = @($usageItems)
        Viewer = $viewer
        Models = @($modelRows)
        LiveModelIds = @($modelIds)
        Errors = @($queryErrors + $modelErrors)
        RefreshedAt = Get-Date
    }
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Accio 模型接入配置"
$form.ClientSize = New-Object System.Drawing.Size(660, 680)
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

$serviceStatusPanel = New-Object System.Windows.Forms.Panel
$serviceStatusPanel.Location = New-Object System.Drawing.Point(30, 239)
$serviceStatusPanel.Size = New-Object System.Drawing.Size(600, 60)
$serviceStatusPanel.BorderStyle = "FixedSingle"
$serviceStatusPanel.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($serviceStatusPanel)

$serviceStatusTitleLabel = New-Object System.Windows.Forms.Label
$serviceStatusTitleLabel.Text = "套餐与模型状态"
$serviceStatusTitleLabel.Location = New-Object System.Drawing.Point(12, 8)
$serviceStatusTitleLabel.Size = New-Object System.Drawing.Size(118, 40)
$serviceStatusTitleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$serviceStatusTitleLabel.TextAlign = "MiddleLeft"
$serviceStatusPanel.Controls.Add($serviceStatusTitleLabel)

$serviceStatusDetailLabel = New-Object System.Windows.Forms.Label
$serviceStatusDetailLabel.Text = "选择火山 Coding Plan 或 Codex 登录后自动查询"
$serviceStatusDetailLabel.Location = New-Object System.Drawing.Point(134, 6)
$serviceStatusDetailLabel.Size = New-Object System.Drawing.Size(292, 46)
$serviceStatusDetailLabel.TextAlign = "MiddleLeft"
$serviceStatusDetailLabel.AutoEllipsis = $true
$serviceStatusDetailLabel.ForeColor = [System.Drawing.Color]::FromArgb(75, 85, 99)
$serviceStatusPanel.Controls.Add($serviceStatusDetailLabel)

$serviceStatusLoginButton = New-Object System.Windows.Forms.Button
$serviceStatusLoginButton.Text = "登录"
$serviceStatusLoginButton.Location = New-Object System.Drawing.Point(438, 14)
$serviceStatusLoginButton.Size = New-Object System.Drawing.Size(68, 30)
$serviceStatusLoginButton.Enabled = $false
$serviceStatusPanel.Controls.Add($serviceStatusLoginButton)

$serviceStatusRefreshButton = New-Object System.Windows.Forms.Button
$serviceStatusRefreshButton.Text = "刷新"
$serviceStatusRefreshButton.Location = New-Object System.Drawing.Point(514, 14)
$serviceStatusRefreshButton.Size = New-Object System.Drawing.Size(68, 30)
$serviceStatusRefreshButton.Enabled = $false
$serviceStatusPanel.Controls.Add($serviceStatusRefreshButton)

$serviceStatusToolTipControl = New-Object System.Windows.Forms.ToolTip

$endpointLabel = New-Object System.Windows.Forms.Label
$endpointLabel.Text = "API 地址"
$endpointLabel.Location = New-Object System.Drawing.Point(30, 311)
$endpointLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($endpointLabel)

$endpointTextBox = New-Object System.Windows.Forms.TextBox
$endpointTextBox.Location = New-Object System.Drawing.Point(30, 336)
$endpointTextBox.Size = New-Object System.Drawing.Size(600, 28)
$form.Controls.Add($endpointTextBox)

$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = "模型名称"
$modelLabel.Location = New-Object System.Drawing.Point(30, 382)
$modelLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($modelLabel)

$modelComboBox = New-Object System.Windows.Forms.ComboBox
$modelComboBox.Location = New-Object System.Drawing.Point(30, 407)
$modelComboBox.Size = New-Object System.Drawing.Size(390, 28)
$modelComboBox.DropDownStyle = "DropDown"
$modelComboBox.AutoCompleteMode = "SuggestAppend"
$modelComboBox.AutoCompleteSource = "ListItems"
$form.Controls.Add($modelComboBox)

$reasoningEffortLabel = New-Object System.Windows.Forms.Label
$reasoningEffortLabel.Text = "思考程度"
$reasoningEffortLabel.Location = New-Object System.Drawing.Point(434, 382)
$reasoningEffortLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($reasoningEffortLabel)

$reasoningEffortComboBox = New-Object System.Windows.Forms.ComboBox
$reasoningEffortComboBox.Location = New-Object System.Drawing.Point(434, 407)
$reasoningEffortComboBox.Size = New-Object System.Drawing.Size(196, 28)
$reasoningEffortComboBox.DropDownStyle = "DropDownList"
$form.Controls.Add($reasoningEffortComboBox)

$apiKeyLabel = New-Object System.Windows.Forms.Label
$apiKeyLabel.Text = "API Key"
$apiKeyLabel.Location = New-Object System.Drawing.Point(30, 453)
$apiKeyLabel.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($apiKeyLabel)

$apiKeyAuthCheckBox = New-Object System.Windows.Forms.CheckBox
$apiKeyAuthCheckBox.Text = "使用 API Key 认证"
$apiKeyAuthCheckBox.Location = New-Object System.Drawing.Point(155, 451)
$apiKeyAuthCheckBox.Size = New-Object System.Drawing.Size(180, 24)
$apiKeyAuthCheckBox.Checked = $true
$form.Controls.Add($apiKeyAuthCheckBox)

$apiKeyTextBox = New-Object System.Windows.Forms.TextBox
$apiKeyTextBox.Location = New-Object System.Drawing.Point(30, 478)
$apiKeyTextBox.Size = New-Object System.Drawing.Size(600, 28)
$apiKeyTextBox.UseSystemPasswordChar = $true
$form.Controls.Add($apiKeyTextBox)

$apiKeyHintLabel = New-Object System.Windows.Forms.Label
$apiKeyHintLabel.Text = "留空将保留已有凭据；取消勾选时不发送 Key，但不会删除已保存的 Key。"
$apiKeyHintLabel.Location = New-Object System.Drawing.Point(30, 511)
$apiKeyHintLabel.Size = New-Object System.Drawing.Size(600, 20)
$apiKeyHintLabel.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$form.Controls.Add($apiKeyHintLabel)

$codexImageCheckBox = New-Object System.Windows.Forms.CheckBox
$codexImageCheckBox.Text = "图片生成使用 Codex 订阅（gpt-image-2，文字模型保持当前选择）"
$codexImageCheckBox.Location = New-Object System.Drawing.Point(30, 543)
$codexImageCheckBox.Size = New-Object System.Drawing.Size(600, 24)
$codexImageCheckBox.Checked = $false
$form.Controls.Add($codexImageCheckBox)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "就绪"
$statusLabel.Location = New-Object System.Drawing.Point(30, 582)
$statusLabel.Size = New-Object System.Drawing.Size(600, 24)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$form.Controls.Add($statusLabel)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "保存配置"
$saveButton.Location = New-Object System.Drawing.Point(330, 622)
$saveButton.Size = New-Object System.Drawing.Size(140, 38)
$form.Controls.Add($saveButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "保存并重启 Accio"
$startButton.Location = New-Object System.Drawing.Point(484, 622)
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

function Get-VolcenginePlanDisplayName([string]$planKey) {
    switch ($planKey) {
        "coding-plan" { return "Coding Plan 个人版" }
        "coding-plan-team" { return "Coding Plan 团队版" }
        default { return $planKey }
    }
}

function Get-VolcenginePeriodDisplayName([string]$label) {
    switch ($label) {
        "session" { return "会话" }
        "5h" { return "5 小时" }
        "daily" { return "每日" }
        "weekly" { return "每周" }
        "monthly" { return "每月" }
        default { return $label }
    }
}

function Get-VolcengineUsageDisplay($period) {
    $percentValue = Get-JsonPropertyValue $period "percent" $null
    $usedValue = Get-JsonPropertyValue $period "used" $null
    $totalValue = Get-JsonPropertyValue $period "total" $null
    if ($null -ne $usedValue -and $null -ne $totalValue) {
        $text = "$usedValue / $totalValue"
        if ($null -ne $percentValue) {
            $text += "（$percentValue%）"
        }
        return $text
    }
    if ($null -ne $percentValue) {
        return "已用 $percentValue%"
    }
    return "未返回额度"
}

function Set-VolcengineLiveModels([string[]]$models, [DateTime]$refreshedAt) {
    $liveModels = @($models | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    if ($liveModels.Count -eq 0) {
        return
    }
    $script:volcengineLiveModels = @($liveModels)
    $script:volcengineModels = @($liveModels)
    $script:volcengineLiveModelsUpdatedAt = $refreshedAt.ToString("o")
    if ($authComboBox.SelectedIndex -eq 0 -and (Get-SelectedApiProvider) -eq $volcengineProvider) {
        $selectedModel = $modelComboBox.Text
        Update-ApiModelOptions $script:volcengineModels $selectedModel
    }
}

function Get-ServiceStatusMode {
    if ($authComboBox.SelectedIndex -eq 1) {
        return "codex"
    }
    if ($authComboBox.SelectedIndex -eq 0 -and (Get-SelectedApiProvider) -eq $volcengineProvider) {
        return "volcengine"
    }
    return "inactive"
}

function Get-ServiceStatusColor([string]$level) {
    switch ($level) {
        "success" { return [System.Drawing.Color]::FromArgb(21, 128, 61) }
        "warning" { return [System.Drawing.Color]::FromArgb(180, 83, 9) }
        "error" { return [System.Drawing.Color]::FromArgb(185, 28, 28) }
        "working" { return [System.Drawing.Color]::FromArgb(37, 99, 235) }
        default { return [System.Drawing.Color]::FromArgb(75, 85, 99) }
    }
}

function Update-ServiceStatusPanel {
    $mode = Get-ServiceStatusMode
    switch ($mode) {
        "volcengine" {
            $serviceStatusTitleLabel.Text = "火山 Coding Plan"
            $serviceStatusDetailLabel.Text = $script:volcengineStatusText
            $serviceStatusDetailLabel.ForeColor = Get-ServiceStatusColor $script:volcengineStatusLevel
            $serviceStatusLoginButton.Enabled = $true
            $serviceStatusRefreshButton.Enabled = -not $script:volcengineRefreshing
            $serviceStatusToolTipControl.SetToolTip($serviceStatusDetailLabel, $script:volcengineStatusToolTip)
        }
        "codex" {
            $serviceStatusTitleLabel.Text = "Codex ChatGPT"
            $serviceStatusDetailLabel.Text = $script:codexStatusText
            $serviceStatusDetailLabel.ForeColor = Get-ServiceStatusColor $script:codexStatusLevel
            $serviceStatusLoginButton.Enabled = $true
            $serviceStatusRefreshButton.Enabled = -not $script:codexRefreshing
            $serviceStatusToolTipControl.SetToolTip($serviceStatusDetailLabel, $script:codexStatusToolTip)
        }
        default {
            $serviceStatusTitleLabel.Text = "套餐与模型状态"
            $serviceStatusDetailLabel.Text = "选择火山 Coding Plan 或 Codex 登录后自动查询"
            $serviceStatusDetailLabel.ForeColor = Get-ServiceStatusColor "idle"
            $serviceStatusLoginButton.Enabled = $false
            $serviceStatusRefreshButton.Enabled = $false
            $serviceStatusToolTipControl.SetToolTip($serviceStatusDetailLabel, "")
        }
    }
}

function Set-ServiceStatusState([string]$mode, [string]$text, [string]$level, [string]$toolTip = "") {
    if ($mode -eq "volcengine") {
        $script:volcengineStatusText = $text
        $script:volcengineStatusLevel = $level
        $script:volcengineStatusToolTip = $toolTip
    } elseif ($mode -eq "codex") {
        $script:codexStatusText = $text
        $script:codexStatusLevel = $level
        $script:codexStatusToolTip = $toolTip
    }
    if ((Get-ServiceStatusMode) -eq $mode) {
        Update-ServiceStatusPanel
    }
}

function Get-VolcengineInlineSummary($dashboard) {
    $planSummaries = New-Object System.Collections.Generic.List[string]
    $detailLines = New-Object System.Collections.Generic.List[string]
    $hasUsageError = $false
    foreach ($plan in @($dashboard.Plans)) {
        $planKey = [string](Get-JsonPropertyValue $plan "key" "")
        $planName = Get-VolcenginePlanDisplayName $planKey
        $tier = [string](Get-JsonPropertyValue $plan "tier" "")
        $planLabel = (@($planName, $tier) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " "
        $usageSummaries = New-Object System.Collections.Generic.List[string]
        foreach ($usageItem in @($dashboard.UsageItems | Where-Object {
            [string](Get-JsonPropertyValue $_ "product" "") -eq $planKey
        })) {
            $usageError = [string](Get-JsonPropertyValue $usageItem "error" "")
            if (-not [string]::IsNullOrWhiteSpace($usageError)) {
                $hasUsageError = $true
                [void]$usageSummaries.Add("用量暂不可读")
                [void]$detailLines.Add("$planLabel / $usageError")
                continue
            }
            foreach ($period in @(Get-JsonPropertyValue $usageItem "periods" @())) {
                $periodName = Get-VolcenginePeriodDisplayName ([string](Get-JsonPropertyValue $period "label" ""))
                $usageText = Get-VolcengineUsageDisplay $period
                [void]$usageSummaries.Add("$periodName $usageText")
                $resetAt = [string](Get-JsonPropertyValue $period "reset_at" "")
                $detail = "$planLabel / $periodName / $usageText"
                if (-not [string]::IsNullOrWhiteSpace($resetAt)) {
                    $detail += " / 重置 $resetAt"
                }
                [void]$detailLines.Add($detail)
            }
        }
        $planSummary = $planLabel
        if ($usageSummaries.Count -gt 0) {
            $planSummary += " · " + ($usageSummaries -join " · ")
        }
        [void]$planSummaries.Add($planSummary)
    }

    $level = "success"
    $firstLine = if ($planSummaries.Count -gt 0) {
        $planSummaries -join "；"
    } else {
        $level = "warning"
        "已登录，但未检测到 Coding Plan 订阅"
    }
    if ($hasUsageError) {
        $level = "warning"
    }
    $modelCount = @($dashboard.LiveModelIds).Count
    $secondLine = "$modelCount 个可用模型 · $($dashboard.RefreshedAt.ToString('HH:mm')) 更新"
    $configuredModel = $modelComboBox.Text
    if ($modelCount -gt 0 -and -not ($dashboard.LiveModelIds -contains $configuredModel)) {
        $level = "warning"
        $secondLine += " · 当前模型不在套餐列表"
        [void]$detailLines.Add("当前配置模型 $configuredModel 不在套餐返回的模型列表中")
    }
    if (@($dashboard.Errors).Count -gt 0) {
        $level = "warning"
        [void]$detailLines.Add("状态查询部分失败：$($dashboard.Errors -join ' | ')")
    }
    [void]$detailLines.Add("官方 Ark CLI：$($dashboard.CliVersion)")
    return [pscustomobject]@{
        Text = "$firstLine`n$secondLine"
        Level = $level
        ToolTip = $detailLines -join [Environment]::NewLine
    }
}

function Get-WorkerFunctionSource([string]$name) {
    $command = Get-Command $name -CommandType Function -ErrorAction Stop
    return "function $name {`n$($command.Definition)`n}`n"
}

function Refresh-VolcengineStatus {
    if ((Get-ServiceStatusMode) -ne "volcengine" -or $script:volcengineRefreshing) {
        return
    }
    $script:volcengineRefreshing = $true
    Set-ServiceStatusState "volcengine" "正在后台读取套餐额度和可用模型..." "working"
    try {
        $functionSources = @(
            "Get-JsonPropertyValue",
            "Get-ArkCliScript",
            "Invoke-ArkCliJson",
            "Get-ArkCliVersion",
            "Get-VolcengineDashboardData"
        ) | ForEach-Object { Get-WorkerFunctionSource $_ }
        $workerScript = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"
$($functionSources -join [Environment]::NewLine)
Get-VolcengineDashboardData | ConvertTo-Json -Depth 12 -Compress
"@
        $script:volcengineRefreshPowerShell = [System.Management.Automation.PowerShell]::Create()
        [void]$script:volcengineRefreshPowerShell.AddScript($workerScript)
        $script:volcengineRefreshAsyncResult = $script:volcengineRefreshPowerShell.BeginInvoke()
        $serviceStatusWorkerTimer.Start()
    } catch {
        if ($null -ne $script:volcengineRefreshPowerShell) {
            $script:volcengineRefreshPowerShell.Dispose()
        }
        $script:volcengineRefreshPowerShell = $null
        $script:volcengineRefreshAsyncResult = $null
        $script:volcengineRefreshing = $false
        Set-ServiceStatusState "volcengine" "火山状态读取失败；点击「刷新」重试" "error" $_.Exception.Message
        Update-ServiceStatusPanel
    }
}

function Complete-VolcengineStatusRefresh {
    if ($null -eq $script:volcengineRefreshAsyncResult -or -not $script:volcengineRefreshAsyncResult.IsCompleted) {
        return
    }
    $worker = $script:volcengineRefreshPowerShell
    try {
        $output = $worker.EndInvoke($script:volcengineRefreshAsyncResult)
        if ($worker.Streams.Error.Count -gt 0) {
            throw [string]$worker.Streams.Error[0]
        }
        $json = @($output | ForEach-Object { [string]$_ } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Last 1)
        if ($json.Count -eq 0) {
            throw "火山状态后台查询没有返回数据"
        }
        $dashboard = $json[0] | ConvertFrom-Json
        $dashboard.RefreshedAt = [datetime]$dashboard.RefreshedAt
        if (-not $dashboard.LoggedIn) {
            $hint = [string](Get-JsonPropertyValue $dashboard.Auth "hint" "请点击登录")
            Set-ServiceStatusState "volcengine" "未登录火山账号；点击「登录」完成浏览器授权" "error" "$($dashboard.CliVersion)`n$hint"
        } else {
            Set-VolcengineLiveModels @($dashboard.LiveModelIds) $dashboard.RefreshedAt
            $summary = Get-VolcengineInlineSummary $dashboard
            Set-ServiceStatusState "volcengine" $summary.Text $summary.Level $summary.ToolTip
        }
    } catch {
        Set-ServiceStatusState "volcengine" "火山状态读取失败；点击「刷新」重试" "error" $_.Exception.Message
    } finally {
        $worker.Dispose()
        $script:volcengineRefreshPowerShell = $null
        $script:volcengineRefreshAsyncResult = $null
        $script:volcengineRefreshing = $false
        Update-ServiceStatusPanel
    }
}

function Get-CodexPlanDisplayName([string]$planType) {
    if ([string]::IsNullOrWhiteSpace($planType)) {
        return "ChatGPT"
    }
    switch ($planType.ToLowerInvariant()) {
        "pro" { return "ChatGPT Pro" }
        "plus" { return "ChatGPT Plus" }
        "team" { return "ChatGPT Team" }
        "business" { return "ChatGPT Business" }
        "enterprise" { return "ChatGPT Enterprise" }
        "edu" { return "ChatGPT Edu" }
        default { return "ChatGPT $planType" }
    }
}

function Get-CodexWindowDisplayName($minutesValue) {
    if ($null -eq $minutesValue) {
        return "额度窗口"
    }
    $minutes = [int]$minutesValue
    if ($minutes -gt 0 -and $minutes % 10080 -eq 0) {
        return "$($minutes / 10080) 周"
    }
    if ($minutes -gt 0 -and $minutes % 1440 -eq 0) {
        return "$($minutes / 1440) 天"
    }
    if ($minutes -gt 0 -and $minutes % 60 -eq 0) {
        return "$($minutes / 60) 小时"
    }
    return "$minutes 分钟"
}

function Get-CodexResetDisplay($unixSeconds) {
    if ($null -eq $unixSeconds) {
        return ""
    }
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$unixSeconds).ToLocalTime().ToString("MM-dd HH:mm")
}

function Get-CompactNumber($value) {
    if ($null -eq $value) {
        return ""
    }
    $number = [double]$value
    if ($number -ge 100000000) {
        return "{0:0.##} 亿" -f ($number / 100000000)
    }
    if ($number -ge 10000) {
        return "{0:0.##} 万" -f ($number / 10000)
    }
    return "{0:N0}" -f $number
}

function Get-CodexStatusSummary($status) {
    if (-not $status.authenticated) {
        return [pscustomobject]@{
            Text = "尚未登录 ChatGPT；点击「登录」完成 Codex 授权"
            Level = "error"
            ToolTip = "Codex 登录由本机 Codex 管理，本程序不读取或导出登录令牌。"
        }
    }

    $planName = Get-CodexPlanDisplayName ([string]$status.planType)
    $limitSummaries = New-Object System.Collections.Generic.List[string]
    $detailLines = New-Object System.Collections.Generic.List[string]
    foreach ($limit in @($status.rateLimits)) {
        $limitName = [string](Get-JsonPropertyValue $limit "limitName" "")
        if ([string]::IsNullOrWhiteSpace($limitName)) {
            $limitName = [string](Get-JsonPropertyValue $limit "limitId" "")
        }
        foreach ($windowName in @("primary", "secondary")) {
            $window = Get-JsonPropertyValue $limit $windowName $null
            if ($null -eq $window) {
                continue
            }
            $duration = Get-CodexWindowDisplayName (Get-JsonPropertyValue $window "windowDurationMins" $null)
            $usedPercent = Get-JsonPropertyValue $window "usedPercent" $null
            $summary = if ($null -ne $usedPercent) { "$duration 已用 $usedPercent%" } else { "$duration 用量未知" }
            if (-not [string]::IsNullOrWhiteSpace($limitName) -and $limitName -ne "codex") {
                $summary = "$limitName $summary"
            }
            [void]$limitSummaries.Add($summary)
            $resetAt = Get-CodexResetDisplay (Get-JsonPropertyValue $window "resetsAt" $null)
            $detail = $summary
            if (-not [string]::IsNullOrWhiteSpace($resetAt)) {
                $detail += " / $resetAt 重置"
            }
            [void]$detailLines.Add($detail)
        }
    }

    $modelCount = @($status.models).Count
    $firstLine = $planName
    if ($limitSummaries.Count -gt 0) {
        $firstLine += " · " + ($limitSummaries -join " · ")
    }
    $secondParts = New-Object System.Collections.Generic.List[string]
    [void]$secondParts.Add("$modelCount 个可用模型")
    if ($status.imageGenerationAvailable) {
        [void]$secondParts.Add("gpt-image-2 可用")
    }
    $lifetimeTokens = Get-JsonPropertyValue $status.usageSummary "lifetimeTokens" $null
    if ($null -ne $lifetimeTokens) {
        [void]$secondParts.Add("累计 $(Get-CompactNumber $lifetimeTokens) Token")
    }
    [void]$secondParts.Add("$((Get-Date).ToString('HH:mm')) 更新")

    $errors = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$status.rateLimitsError)) {
        [void]$errors.Add("额度：$($status.rateLimitsError)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$status.usageError)) {
        [void]$errors.Add("Token：$($status.usageError)")
    }
    $level = if ($errors.Count -gt 0) { "warning" } else { "success" }
    if ($errors.Count -gt 0) {
        [void]$secondParts.Add("部分用量暂不可读")
        [void]$detailLines.Add(($errors -join [Environment]::NewLine))
    }
    return [pscustomobject]@{
        Text = "$firstLine`n$($secondParts -join ' · ')"
        Level = $level
        ToolTip = $detailLines -join [Environment]::NewLine
    }
}

function Start-CurrentServiceLogin {
    switch (Get-ServiceStatusMode) {
        "volcengine" {
            $arkCliScript = Get-ArkCliScript
            $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
            Start-Process -FilePath $powershellExe -ArgumentList @(
                "-NoExit",
                "-NoProfile",
                "-File", "`"$arkCliScript`"",
                "auth", "login", "volc-sso"
            )
            Set-ServiceStatusState "volcengine" "登录窗口已打开；授权完成后点击「刷新」" "working"
        }
        "codex" {
            $codexExe = Get-CodexExecutable
            Start-Process -FilePath $codexExe -ArgumentList "login"
            Set-ServiceStatusState "codex" "Codex 登录已启动；完成授权后点击「刷新」" "working"
        }
    }
}

function Refresh-CurrentServiceStatus {
    switch (Get-ServiceStatusMode) {
        "volcengine" { Refresh-VolcengineStatus }
        "codex" { Refresh-CodexStatus }
    }
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
            $modelLabel.Text = "模型名称（套餐自动查询）"
            $apiKeyHintLabel.Text = "留空将保留火山 Coding Plan 已有凭据；该 Key 与 OpenCode Go 完全分开保存。"
        } elseif ($apiProvider -eq $customApiProvider) {
            Update-ApiModelOptions @() $settings.Model
            $modelLabel.Text = "模型名称"
            $apiKeyHintLabel.Text = "留空将保留自定义 API 已有凭据；取消勾选时不发送 Key。"
        } else {
            Update-ApiModelOptions $openCodeModels $settings.Model
            $modelLabel.Text = "模型名称"
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
    Update-ServiceStatusPanel
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
        $modelLabel.Text = "模型名称（Codex 自动查询）"
        $modelComboBox.Text = $script:lastCodexModel
        Update-ReasoningEfforts $script:lastCodexReasoningEffort
    } elseif ($usesNative) {
        $endpointTextBox.Text = $nativeEndpoint
        $modelLabel.Text = "模型名称"
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
    Update-ServiceStatusPanel
    $script:previousAuthIndex = $authComboBox.SelectedIndex
}

function Apply-CodexStatus($status) {
    if ($authComboBox.SelectedIndex -eq 1) {
        $selectedModel = $modelComboBox.Text
        $selectedReasoningEffort = $reasoningEffortComboBox.Text
        $script:codexModelsById.Clear()
        $modelComboBox.BeginUpdate()
        try {
            $modelComboBox.Items.Clear()
            foreach ($item in $status.models) {
                [void]$modelComboBox.Items.Add([string]$item.id)
                $script:codexModelsById[[string]$item.id] = $item
            }
        } finally {
            $modelComboBox.EndUpdate()
        }
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
    $summary = Get-CodexStatusSummary $status
    Set-ServiceStatusState "codex" $summary.Text $summary.Level $summary.ToolTip
    if ($codexImageCheckBox.Checked -and (Get-ServiceStatusMode) -ne "codex") {
        $statusLabel.Text = if ($status.authenticated -and $status.imageGenerationAvailable) {
            "Codex 图片通道已登录，gpt-image-2 可用"
        } elseif ($status.authenticated) {
            "Codex 已登录，但图片生成当前不可用"
        } else {
            "Codex 图片通道尚未登录"
        }
        $statusLabel.ForeColor = if ($status.authenticated -and $status.imageGenerationAvailable) {
            [System.Drawing.Color]::FromArgb(21, 128, 61)
        } else {
            [System.Drawing.Color]::FromArgb(180, 83, 9)
        }
    }
}

function Refresh-CodexStatus {
    if ($script:codexRefreshing) {
        return
    }
    $script:codexRefreshing = $true
    Set-ServiceStatusState "codex" "正在后台读取 Codex 登录、额度和模型..." "working"
    try {
        $functionSources = @(
            "Get-CodexExecutable",
            "Get-CodexStatus"
        ) | ForEach-Object { Get-WorkerFunctionSource $_ }
        $workerScript = @"
param([string]`$nodeExe, [string]`$codexStatusScript)
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"
$($functionSources -join [Environment]::NewLine)
Get-CodexStatus | ConvertTo-Json -Depth 12 -Compress
"@
        $script:codexRefreshPowerShell = [System.Management.Automation.PowerShell]::Create()
        [void]$script:codexRefreshPowerShell.AddScript($workerScript).AddArgument($nodeExe).AddArgument($codexStatusScript)
        $script:codexRefreshAsyncResult = $script:codexRefreshPowerShell.BeginInvoke()
        $serviceStatusWorkerTimer.Start()
    } catch {
        if ($null -ne $script:codexRefreshPowerShell) {
            $script:codexRefreshPowerShell.Dispose()
        }
        $script:codexRefreshPowerShell = $null
        $script:codexRefreshAsyncResult = $null
        $script:codexRefreshing = $false
        Set-ServiceStatusState "codex" "Codex 状态读取失败；点击「刷新」重试" "error" $_.Exception.Message
        Update-ServiceStatusPanel
    }
}

function Complete-CodexStatusRefresh {
    if ($null -eq $script:codexRefreshAsyncResult -or -not $script:codexRefreshAsyncResult.IsCompleted) {
        return
    }
    $worker = $script:codexRefreshPowerShell
    try {
        $output = $worker.EndInvoke($script:codexRefreshAsyncResult)
        if ($worker.Streams.Error.Count -gt 0) {
            throw [string]$worker.Streams.Error[0]
        }
        $json = @($output | ForEach-Object { [string]$_ } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Last 1)
        if ($json.Count -eq 0) {
            throw "Codex 状态后台查询没有返回数据"
        }
        Apply-CodexStatus ($json[0] | ConvertFrom-Json)
    } catch {
        Set-ServiceStatusState "codex" "Codex 状态读取失败；点击「刷新」重试" "error" $_.Exception.Message
        if ((Get-ServiceStatusMode) -ne "codex") {
            $statusLabel.Text = "Codex 图片通道状态读取失败"
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
        }
    } finally {
        $worker.Dispose()
        $script:codexRefreshPowerShell = $null
        $script:codexRefreshAsyncResult = $null
        $script:codexRefreshing = $false
        Update-ServiceStatusPanel
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
        volcengineLiveModels = @($script:volcengineLiveModels)
        volcengineLiveModelsUpdatedAt = $script:volcengineLiveModelsUpdatedAt
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
    if ($script:formShown) {
        Refresh-CurrentServiceStatus
    }
})

$codexImageCheckBox.Add_CheckedChanged({
    Update-ModeControls
    if ($script:formShown -and $codexImageCheckBox.Checked -and (Get-ServiceStatusMode) -ne "codex") {
        Refresh-CodexStatus
    }
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
    if ($script:formShown -and (Get-ServiceStatusMode) -eq "volcengine") {
        Refresh-VolcengineStatus
    }
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

$serviceStatusRefreshButton.Add_Click({
    try {
        Refresh-CurrentServiceStatus
    } catch {
        Show-ConfigurationError $_.Exception.Message
    }
})

$serviceStatusLoginButton.Add_Click({
    try {
        Start-CurrentServiceLogin
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
        $output = & powershell.exe -NoProfile -File $launcherPath -RestartBridge -RestartAccio 2>&1
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
    if ($null -ne $config.PSObject.Properties["volcengineLiveModels"]) {
        $loadedVolcengineModels = @($config.volcengineLiveModels | ForEach-Object { [string]$_ } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Sort-Object -Unique)
        if ($loadedVolcengineModels.Count -gt 0) {
            $volcengineLiveModels = @($loadedVolcengineModels)
            $volcengineModels = @($loadedVolcengineModels)
        }
    }
    if ($null -ne $config.PSObject.Properties["volcengineLiveModelsUpdatedAt"]) {
        $volcengineLiveModelsUpdatedAt = [string]$config.volcengineLiveModelsUpdatedAt
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

$serviceStatusWorkerTimer = New-Object System.Windows.Forms.Timer
$serviceStatusWorkerTimer.Interval = 100
$serviceStatusWorkerTimer.Add_Tick({
    Complete-VolcengineStatusRefresh
    Complete-CodexStatusRefresh
    if ($null -eq $script:volcengineRefreshAsyncResult -and $null -eq $script:codexRefreshAsyncResult) {
        $serviceStatusWorkerTimer.Stop()
    }
})

$serviceStatusRefreshTimer = New-Object System.Windows.Forms.Timer
$serviceStatusRefreshTimer.Interval = $arkCliRefreshIntervalMs
$serviceStatusRefreshTimer.Add_Tick({
    Refresh-CurrentServiceStatus
})

$form.Add_Shown({
    $script:formShown = $true
    $serviceStatusRefreshTimer.Start()
    if ($authComboBox.SelectedIndex -eq 1 -or $codexImageCheckBox.Checked) {
        Refresh-CodexStatus
    }
    if ((Get-ServiceStatusMode) -eq "volcengine") {
        Refresh-VolcengineStatus
    }
})

[void]$form.ShowDialog()
$serviceStatusRefreshTimer.Stop()
$serviceStatusRefreshTimer.Dispose()
$serviceStatusWorkerTimer.Stop()
$serviceStatusWorkerTimer.Dispose()
foreach ($worker in @($script:volcengineRefreshPowerShell, $script:codexRefreshPowerShell)) {
    if ($null -ne $worker) {
        $worker.Stop()
        $worker.Dispose()
    }
}
