param(
    [switch]$StoreCredential,
    [switch]$BackendOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$credentialTarget = "AccioOpenCodeGoApiKey"
$localGatewayCredentialTarget = "AccioLocalGatewayPassword"
$relayUrl = "http://127.0.0.1:18767"
$bridgeUrl = "http://127.0.0.1:18765"
$model = "deepseek-v4-flash"
$endpoint = "https://opencode.ai/zen/go/v1/chat/completions"
$nodeExe = "C:\Program Files\nodejs\node.exe"
$accioExe = Join-Path $env:LOCALAPPDATA "Programs\Accio\Accio.exe"
$bridgeScript = Join-Path $PSScriptRoot "accio_opencode_bridge.js"
$relayScript = Join-Path $PSScriptRoot "accio_gateway_relay.js"
$relayLog = Join-Path $PSScriptRoot "accio_gateway_relay.log"

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
    Write-Output "OpenCode Go credential stored in Windows Credential Manager."
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

$bridgeHealth = Get-Health "$bridgeUrl/healthz"
if ($null -eq $bridgeHealth) {
    $apiKey = [AccioOpenCode.NativeCredential]::Read($credentialTarget)
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "OpenCode Go credential is empty"
    }
    $env:OPENCODE_GO_API_KEY = $apiKey
    $env:OPENCODE_GO_MODEL = $model
    $env:OPENCODE_GO_ENDPOINT = $endpoint
    Start-Process -FilePath $nodeExe -ArgumentList $bridgeScript -WindowStyle Hidden
    Remove-Item Env:OPENCODE_GO_API_KEY
    $apiKey = $null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        $bridgeHealth = Get-Health "$bridgeUrl/healthz"
        if ($null -ne $bridgeHealth) { break }
    }
}
if ($null -eq $bridgeHealth -or $bridgeHealth.model -ne $model -or $bridgeHealth.endpoint -ne $endpoint -or -not $bridgeHealth.apiKeyConfigured) {
    throw "OpenCode Go bridge health check failed"
}

$relayHealth = Get-Health "$relayUrl/healthz"
if ($null -eq $relayHealth) {
    $env:ACCIO_RELAY_PORT = "18767"
    $env:ACCIO_RELAY_LOG = $relayLog
    $env:ACCIO_LOCAL_GATEWAY_PASSWORD = $localGatewayPassword
    Start-Process -FilePath $nodeExe -ArgumentList $relayScript -WindowStyle Hidden
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        $relayHealth = Get-Health "$relayUrl/healthz"
        if ($null -ne $relayHealth) { break }
    }
}
if ($null -eq $relayHealth -or $relayHealth.modelBridge -ne $bridgeUrl -or $relayHealth.originalGateway -ne "https://phoenix-gw.alibaba.com") {
    throw "Accio relay health check failed"
}

if (-not $BackendOnly -and -not (Get-Process -Name "Accio" -ErrorAction SilentlyContinue)) {
    $env:GATEWAY_BASE_URL = $relayUrl
    $env:FAST_BUILD = "true"
    $env:ACCIO_DEV_GATEWAY_PASSWORD = $localGatewayPassword
    Start-Process -FilePath $accioExe
}

Write-Output "Accio OpenCode Go backend is ready."
