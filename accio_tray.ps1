Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$configUiPath = Join-Path $PSScriptRoot "accio_config_ui.ps1"
$launcherPath = Join-Path $PSScriptRoot "accio_opencode_launcher.ps1"
$configPath = Join-Path $env:LOCALAPPDATA "AccioModelApiAuth\config.json"
$accioExe = Join-Path $env:LOCALAPPDATA "Programs\Accio\Accio.exe"
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, "Local\AccioModelApiAuthTray", [ref]$createdNew)

if (-not $createdNew) {
    $mutex.Dispose()
    return
}

$icon = $null
$menu = $null
$notifyIcon = $null
$statusTimer = $null

function Get-CurrentModeSummary {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ([string]$config.authType -eq "accio_native") {
        return "Accio 官方原生认证"
    }
    if ([string]$config.authType -eq "codex_chatgpt") {
        $reasoning = if ([string]::IsNullOrWhiteSpace([string]$config.reasoningEffort)) { "默认思考强度" } else { [string]$config.reasoningEffort }
        return "Codex / $([string]$config.model) / $reasoning"
    }
    if ([string]$config.authType -eq "none") {
        return "无认证 API / $([string]$config.model)"
    }
    return "API Key / $([string]$config.model)"
}

function Update-TrayStatus {
    try {
        $summary = Get-CurrentModeSummary
    } catch {
        $summary = "配置读取失败"
    }
    $script:statusItem.Text = "当前：$summary"
    $tooltip = "Accio 模型认证：$summary"
    if ($tooltip.Length -gt 63) {
        $tooltip = $tooltip.Substring(0, 63)
    }
    $script:notifyIcon.Text = $tooltip
}

function Show-TrayMessage([string]$title, [string]$message) {
    $script:notifyIcon.ShowBalloonTip(
        3000,
        $title,
        $message,
        [System.Windows.Forms.ToolTipIcon]::Info
    )
}

function Show-TrayError([string]$message) {
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        "Accio 模型认证托盘",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Open-Configuration {
    Start-Process -FilePath $powershellExe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$configUiPath`"" `
        -WindowStyle Hidden
}

function Get-AccioProcesses {
    $processes = @()
    foreach ($process in @(Get-Process -Name "Accio" -ErrorAction SilentlyContinue)) {
        try {
            if ([string]::Equals($process.Path, $accioExe, [StringComparison]::OrdinalIgnoreCase)) {
                $processes += $process
            }
        } catch {}
    }
    return $processes
}

function Invoke-Launcher([string[]]$launcherArguments) {
    $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $launcherPath @launcherArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output | Out-String)
    }
    return ($output | Out-String).Trim()
}

try {
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($accioExe)
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    [void]$menu.Items.Add($statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $openConfigItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $openConfigItem.Text = "打开认证配置"
    [void]$menu.Items.Add($openConfigItem)

    $applyItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $applyItem.Text = "应用当前配置并重启 Accio"
    [void]$menu.Items.Add($applyItem)

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $startItem.Text = "启动 Accio"
    [void]$menu.Items.Add($startItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = "退出托盘"
    [void]$menu.Items.Add($exitItem)

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = $icon
    $notifyIcon.ContextMenuStrip = $menu
    $notifyIcon.Visible = $true

    $openConfigAction = {
        try {
            Open-Configuration
        } catch {
            Show-TrayError $_.Exception.Message
        }
    }
    $openConfigItem.Add_Click($openConfigAction)
    $notifyIcon.Add_DoubleClick($openConfigAction)

    $applyItem.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "应用当前认证配置需要重启 Accio。正在运行的任务或未发送内容可能丢失。是否继续？",
            "确认重启 Accio",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
        try {
            $statusItem.Text = "正在应用配置并重启 Accio..."
            [System.Windows.Forms.Application]::DoEvents()
            [void](Invoke-Launcher @("-RestartBridge", "-RestartAccio"))
            Update-TrayStatus
            Show-TrayMessage "Accio 模型认证" "当前配置已应用，Accio 已重新启动。"
        } catch {
            Update-TrayStatus
            Show-TrayError $_.Exception.Message
        }
    })

    $startItem.Add_Click({
        if (@(Get-AccioProcesses).Count -gt 0) {
            Show-TrayMessage "Accio" "Accio 已在运行。"
            return
        }
        try {
            $statusItem.Text = "正在启动 Accio..."
            [System.Windows.Forms.Application]::DoEvents()
            [void](Invoke-Launcher @())
            Update-TrayStatus
            Show-TrayMessage "Accio" "Accio 已启动。"
        } catch {
            Update-TrayStatus
            Show-TrayError $_.Exception.Message
        }
    })

    $exitItem.Add_Click({
        $notifyIcon.Visible = $false
        [System.Windows.Forms.Application]::ExitThread()
    })

    $statusTimer = New-Object System.Windows.Forms.Timer
    $statusTimer.Interval = 3000
    $statusTimer.Add_Tick({ Update-TrayStatus })
    $statusTimer.Start()
    Update-TrayStatus
    [System.Windows.Forms.Application]::Run()
} catch {
    Show-TrayError $_.Exception.Message
} finally {
    if ($null -ne $statusTimer) {
        $statusTimer.Stop()
        $statusTimer.Dispose()
    }
    if ($null -ne $notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    if ($null -ne $menu) {
        $menu.Dispose()
    }
    if ($null -ne $icon) {
        $icon.Dispose()
    }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
