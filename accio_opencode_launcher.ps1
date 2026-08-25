param(
    [switch]$StoreCredential,
    [switch]$BackendOnly,
    [switch]$RestartBridge,
    [switch]$RestartAccio
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$credentialTarget = "AccioOpenCodeGoApiKey"
$localGatewayCredentialTarget = "AccioLocalGatewayPassword"
$relayUrl = "http://127.0.0.1:18767"
$bridgeUrl = "http://127.0.0.1:18765"
$model = "deepseek-v4-flash"
$endpoint = "https://opencode.ai/zen/go/v1/chat/completions"
$authType = "api_key"
$reasoningEffort = ""
$configDirectory = Join-Path $env:LOCALAPPDATA "AccioModelApiAuth"
$configPath = Join-Path $configDirectory "config.json"
$nodeExe = "C:\Program Files\nodejs\node.exe"
$accioExe = Join-Path $env:LOCALAPPDATA "Programs\Accio\Accio.exe"
$openAiBridgeScript = Join-Path $PSScriptRoot "accio_opencode_bridge.cjs"
$legacyOpenAiBridgeScript = Join-Path $PSScriptRoot "accio_opencode_bridge.js"
$codexBridgeScript = Join-Path $PSScriptRoot "accio_codex_bridge.js"
$relayScript = Join-Path $PSScriptRoot "accio_gateway_relay.js"
$relayLog = Join-Path $PSScriptRoot "accio_gateway_relay.log"

if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $model = [string]$config.model
    $endpoint = [string]$config.endpoint
    $authType = [string]$config.authType
    if ($null -ne $config.PSObject.Properties["reasoningEffort"]) {
        $reasoningEffort = [string]$config.reasoningEffort
    }
    if ($authType -eq "codex_chatgpt" -and [string]::IsNullOrWhiteSpace($reasoningEffort) -and
        $null -ne $config.PSObject.Properties["codexReasoningEffort"]) {
        $reasoningEffort = [string]$config.codexReasoningEffort
    }
    if (($authType -eq "api_key" -or $authType -eq "none") -and [string]::IsNullOrWhiteSpace($reasoningEffort)) {
        if ($null -ne $config.PSObject.Properties["openAiReasoningEffort"] -and
            -not [string]::IsNullOrWhiteSpace([string]$config.openAiReasoningEffort)) {
            $reasoningEffort = [string]$config.openAiReasoningEffort
        } else {
            $reasoningEffort = "high"
        }
    }
}
if ($authType -eq "codex_chatgpt") {
    $endpoint = "codex-app-server://local"
    $bridgeScript = $codexBridgeScript
} else {
    $bridgeScript = $openAiBridgeScript
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

function Stop-AccioProcesses {
    $processes = @(Get-AccioProcesses)
    if ($processes.Count -eq 0) {
        return
    }
    foreach ($process in @($processes | Where-Object { $_.MainWindowHandle -ne 0 })) {
        [void]$process.CloseMainWindow()
    }
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        Start-Sleep -Milliseconds 100
        if (@(Get-AccioProcesses).Count -eq 0) {
            return
        }
    }
    $remaining = @(Get-AccioProcesses)
    if ($remaining.Count -gt 0) {
        Stop-Process -Id $remaining.Id -Force
    }
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 100
        if (@(Get-AccioProcesses).Count -eq 0) {
            return
        }
    }
    throw "Accio did not stop"
}

function Restore-AccioModelCacheLabels {
    $modelCachePath = Join-Path $env:USERPROFILE ".accio\model_cache.json"
    if (-not (Test-Path -LiteralPath $modelCachePath)) {
        return
    }
    $cache = Get-Content -LiteralPath $modelCachePath -Raw | ConvertFrom-Json
    if ($null -eq $cache.PSObject.Properties["snapshots"]) {
        return
    }
    $separator = " | Accio: "
    $changed = $false
    foreach ($snapshotProperty in $cache.snapshots.PSObject.Properties) {
        $snapshot = $snapshotProperty.Value
        foreach ($provider in @($snapshot.data)) {
            foreach ($item in @($provider.modelList)) {
                if ($null -eq $item.PSObject.Properties["modelDisplayName"]) {
                    continue
                }
                $displayName = [string]$item.modelDisplayName
                $separatorIndex = $displayName.IndexOf($separator, [StringComparison]::Ordinal)
                if ($separatorIndex -ge 0) {
                    $item.modelDisplayName = $displayName.Substring($separatorIndex + $separator.Length).Trim()
                    $changed = $true
                }
            }
        }
        if ($null -eq $snapshot.PSObject.Properties["ext"]) {
            continue
        }
        foreach ($label in @($snapshot.ext.labelList)) {
            if ($null -eq $label.PSObject.Properties["displayName"]) {
                continue
            }
            $displayName = [string]$label.displayName
            $separatorIndex = $displayName.IndexOf($separator, [StringComparison]::Ordinal)
            if ($separatorIndex -ge 0) {
                $label.displayName = $displayName.Substring($separatorIndex + $separator.Length).Trim()
                $changed = $true
            }
        }
        if ($null -ne $snapshot.ext.PSObject.Properties["version"]) {
            $version = [string]$snapshot.ext.version
            $markerIndex = $version.IndexOf("-actual-", [StringComparison]::Ordinal)
            if ($markerIndex -ge 0) {
                $snapshot.ext.version = $version.Substring(0, $markerIndex)
                $changed = $true
            }
        }
    }
    if ($changed) {
        $json = $cache | ConvertTo-Json -Depth 100
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($modelCachePath, $json, $utf8NoBom)
    }
}

if ($authType -eq "accio_native" -and -not $StoreCredential) {
    if ($BackendOnly) {
        Write-Output "Accio native authentication does not require a local backend."
        return
    }
    if (@(Get-AccioProcesses).Count -gt 0 -and -not $RestartAccio) {
        throw "Accio is already running. Use -RestartAccio to apply native authentication."
    }
    if ($RestartAccio) {
        Stop-AccioProcesses
    }
    Restore-AccioModelCacheLabels
    Remove-Item Env:GATEWAY_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:FAST_BUILD -ErrorAction SilentlyContinue
    Remove-Item Env:ACCIO_DEV_GATEWAY_PASSWORD -ErrorAction SilentlyContinue
    if (@(Get-AccioProcesses).Count -eq 0) {
        Start-Process -FilePath $accioExe
    }
    Write-Output "Accio is ready with native authentication and official models."
    return
}

if (-not (Test-Path -LiteralPath $nodeExe)) {
    throw "Node.js was not found at $nodeExe"
}

if (-not ("AccioOpenCode.NativeCredential" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace AccioOpenCode {
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

        [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credentialPtr);

        [DllImport("Advapi32.dll", SetLastError = false)]
        private static extern void CredFree(IntPtr credentialPtr);

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
                    UserName = "OpenCode Go"
                };
                if (!CredWrite(ref credential, 0)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            } finally {
                Array.Clear(blob, 0, blob.Length);
                handle.Free();
            }
        }

        public static string Read(string target) {
            IntPtr credentialPtr;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out credentialPtr)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            try {
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(credentialPtr, typeof(CREDENTIAL));
                if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0) {
                    return "";
                }
                return Marshal.PtrToStringUni(credential.CredentialBlob, (int)credential.CredentialBlobSize / 2);
            } finally {
                CredFree(credentialPtr);
            }
        }
    }
}
'@
}

if ($StoreCredential) {
    $secureKey = Read-Host "OpenCode Go API Key" -AsSecureString
    $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    try {
        $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        if ([string]::IsNullOrWhiteSpace($plainKey)) {
            throw "API Key cannot be empty"
        }
        [AccioOpenCode.NativeCredential]::Write($credentialTarget, $plainKey)
    } finally {
        $plainKey = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    Write-Output "Model API credential stored in Windows Credential Manager."
    return
}

try {
    $localGatewayPassword = [AccioOpenCode.NativeCredential]::Read($localGatewayCredentialTarget)
} catch [System.ComponentModel.Win32Exception] {
    if ($_.Exception.NativeErrorCode -ne 1168) {
        throw
    }
    $localGatewayPassword = [Guid]::NewGuid().ToString("N")
    [AccioOpenCode.NativeCredential]::Write($localGatewayCredentialTarget, $localGatewayPassword)
}
if ([string]::IsNullOrWhiteSpace($localGatewayPassword)) {
    throw "Accio local gateway credential is empty"
}

function Get-Health([string]$url) {
    try {
        return Invoke-RestMethod -Uri $url -TimeoutSec 2 -ErrorAction Stop
    } catch {
        return $null
    }
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
    throw "A complete Codex installation with codex-code-mode-host.exe was not found"
}

function Stop-BridgeProcess {
    $connection = Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 18765 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $connection) {
        return
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($connection.OwningProcess)"
    $knownBridge = $false
    if ($null -ne $process -and -not [string]::IsNullOrWhiteSpace($process.CommandLine)) {
        foreach ($knownScript in @($openAiBridgeScript, $legacyOpenAiBridgeScript, $codexBridgeScript)) {
            if ($process.CommandLine.IndexOf($knownScript, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $knownBridge = $true
                break
            }
        }
    }
    if (-not $knownBridge) {
        throw "Port 18765 is owned by an unexpected process"
    }
    Stop-Process -Id $connection.OwningProcess -Force
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 100
        if ($null -eq (Get-Health "$bridgeUrl/healthz")) {
            return
        }
    }
    throw "Accio model bridge did not stop"
}

$bridgeHealth = Get-Health "$bridgeUrl/healthz"
$bridgeAuthType = ""
$bridgeReasoningEffort = ""
if ($null -ne $bridgeHealth -and $null -ne $bridgeHealth.PSObject.Properties["authType"]) {
    $bridgeAuthType = [string]$bridgeHealth.authType
}
$expectedReasoningEffort = if (-not [string]::IsNullOrWhiteSpace($reasoningEffort)) { $reasoningEffort } else { "default" }
if ($null -ne $bridgeHealth -and $null -ne $bridgeHealth.PSObject.Properties["reasoningEffort"]) {
    $bridgeReasoningEffort = [string]$bridgeHealth.reasoningEffort
}
$bridgeConfigurationChanged = $null -ne $bridgeHealth -and (
    $bridgeHealth.model -ne $model -or
    $bridgeHealth.endpoint -ne $endpoint -or
    $bridgeAuthType -ne $authType -or
    $bridgeReasoningEffort -ne $expectedReasoningEffort
)
if ($null -ne $bridgeHealth -and ($RestartBridge -or $bridgeConfigurationChanged)) {
    Stop-BridgeProcess
    $bridgeHealth = $null
}
if ($null -eq $bridgeHealth) {
    if ($authType -eq "api_key") {
        $apiKey = [AccioOpenCode.NativeCredential]::Read($credentialTarget)
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            throw "Model API credential is empty"
        }
        $env:OPENCODE_GO_API_KEY = $apiKey
        $env:OPENCODE_GO_MODEL = $model
        $env:OPENCODE_GO_ENDPOINT = $endpoint
        $env:OPENCODE_GO_REASONING_EFFORT = $reasoningEffort
        $env:ACCIO_MODEL_AUTH_TYPE = $authType
    } elseif ($authType -eq "none") {
        Remove-Item Env:OPENCODE_GO_API_KEY -ErrorAction SilentlyContinue
        $env:OPENCODE_GO_MODEL = $model
        $env:OPENCODE_GO_ENDPOINT = $endpoint
        $env:OPENCODE_GO_REASONING_EFFORT = $reasoningEffort
        $env:ACCIO_MODEL_AUTH_TYPE = $authType
    } elseif ($authType -eq "codex_chatgpt") {
        Remove-Item Env:OPENCODE_GO_API_KEY -ErrorAction SilentlyContinue
        $env:ACCIO_CODEX_EXE = Get-CodexExecutable
        $env:ACCIO_CODEX_MODEL = $model
        if ([string]::IsNullOrWhiteSpace($reasoningEffort)) {
            Remove-Item Env:ACCIO_CODEX_REASONING_EFFORT -ErrorAction SilentlyContinue
        } else {
            $env:ACCIO_CODEX_REASONING_EFFORT = $reasoningEffort
        }
        $env:ACCIO_CODEX_CWD = $PSScriptRoot
    } else {
        throw "Unsupported authentication type: $authType"
    }
    Start-Process -FilePath $nodeExe -ArgumentList "`"$bridgeScript`"" -WindowStyle Hidden
    if ($authType -eq "api_key" -or $authType -eq "none") {
        Remove-Item Env:OPENCODE_GO_API_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:OPENCODE_GO_REASONING_EFFORT -ErrorAction SilentlyContinue
        $apiKey = $null
    }
    if ($authType -eq "codex_chatgpt") {
        Remove-Item Env:ACCIO_CODEX_EXE
        Remove-Item Env:ACCIO_CODEX_MODEL
        Remove-Item Env:ACCIO_CODEX_REASONING_EFFORT -ErrorAction SilentlyContinue
        Remove-Item Env:ACCIO_CODEX_CWD
    }
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        $bridgeHealth = Get-Health "$bridgeUrl/healthz"
        if ($null -ne $bridgeHealth) { break }
    }
}

$authenticationReady = $false
if ($null -ne $bridgeHealth) {
    if ($authType -eq "api_key") {
        $authenticationReady = $null -ne $bridgeHealth.PSObject.Properties["apiKeyConfigured"] -and [bool]$bridgeHealth.apiKeyConfigured
    } elseif ($authType -eq "none") {
        $authenticationReady = $true
    } elseif ($authType -eq "codex_chatgpt") {
        $authenticationReady = $null -ne $bridgeHealth.PSObject.Properties["authenticated"] -and [bool]$bridgeHealth.authenticated
    }
}
if ($null -eq $bridgeHealth -or $bridgeHealth.model -ne $model -or $bridgeHealth.endpoint -ne $endpoint -or
    $bridgeHealth.authType -ne $authType -or
    $bridgeHealth.reasoningEffort -ne $expectedReasoningEffort -or
    -not $authenticationReady) {
    throw "Accio model bridge health check failed"
}

$relayHealth = Get-Health "$relayUrl/healthz"
if ($null -eq $relayHealth) {
    $env:ACCIO_RELAY_PORT = "18767"
    $env:ACCIO_RELAY_LOG = $relayLog
    $env:ACCIO_LOCAL_GATEWAY_PASSWORD = $localGatewayPassword
    Start-Process -FilePath $nodeExe -ArgumentList "`"$relayScript`"" -WindowStyle Hidden
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        $relayHealth = Get-Health "$relayUrl/healthz"
        if ($null -ne $relayHealth) { break }
    }
}
if ($null -eq $relayHealth -or $relayHealth.modelBridge -ne $bridgeUrl -or $relayHealth.originalGateway -ne "https://phoenix-gw.alibaba.com") {
    throw "Accio relay health check failed"
}

if (-not $BackendOnly) {
    if ($RestartAccio) {
        Stop-AccioProcesses
    }
    if (@(Get-AccioProcesses).Count -eq 0) {
        $env:GATEWAY_BASE_URL = $relayUrl
        $env:FAST_BUILD = "true"
        $env:ACCIO_DEV_GATEWAY_PASSWORD = $localGatewayPassword
        Start-Process -FilePath $accioExe
    }
}

Write-Output "Accio model API backend is ready: $authType / $model / $expectedReasoningEffort"
