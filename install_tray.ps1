param(
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$accioExe = Join-Path $env:LOCALAPPDATA "Programs\Accio\Accio.exe"
$trayPath = Join-Path $PSScriptRoot "accio_tray.ps1"
$configUiPath = Join-Path $PSScriptRoot "accio_config_ui.ps1"
$desktopPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)) "Accio 模型认证配置.lnk"
$programsPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) "Accio 模型认证配置.lnk"
$startupPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) "Accio 模型认证托盘.lnk"

function New-AccioShortcut(
    [string]$shortcutPath,
    [string]$scriptPath,
    [string]$description
) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellExe
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = "$accioExe,0"
    $shortcut.Description = $description
    $shortcut.Save()
}

New-AccioShortcut $desktopPath $configUiPath "打开 Accio 模型认证配置"
New-AccioShortcut $programsPath $configUiPath "打开 Accio 模型认证配置"
New-AccioShortcut $startupPath $trayPath "登录 Windows 后启动 Accio 模型认证托盘"

if (-not $NoStart) {
    Start-Process -FilePath $powershellExe `
        -ArgumentList "-NoProfile -WindowStyle Hidden -File `"$trayPath`"" `
        -WindowStyle Hidden
}

Write-Output "Desktop shortcut: $desktopPath"
Write-Output "Start menu shortcut: $programsPath"
Write-Output "Startup shortcut: $startupPath"
