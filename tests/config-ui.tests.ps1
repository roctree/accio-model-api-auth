Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$uiPath = Join-Path $repoRoot 'accio_config_ui.ps1'

# Parse every PowerShell file, but never dot-source the UI or the launcher.
foreach ($file in Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -Recurse) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
}
Write-Output 'PASS: PowerShell syntax'

$uiAst = [System.Management.Automation.Language.Parser]::ParseFile($uiPath, [ref]$null, [ref]$null)
$functionNames = @(
    'Get-JsonPropertyValue', 'Get-VolcengineDashboardData', 'Get-VolcengineUsageDisplay',
    'Get-ApiProviderFromIndex', 'Get-SelectedApiProvider', 'Get-VolcengineReasoningEfforts',
    'Get-ReasoningEffortDisplayName', 'Get-ApiReasoningEffort', 'Get-SelectedApiReasoningEffort',
    'Update-ApiReasoningEfforts', 'Update-ApiModelOptions', 'Set-VolcengineLiveModels',
    'Update-ReasoningEfforts', 'Apply-CodexStatus', 'Get-CodexStatusSummary',
    'Get-CodexPlanDisplayName', 'Get-CodexWindowDisplayName', 'Get-CodexResetDisplay', 'Get-CompactNumber'
)
foreach ($name in $functionNames) {
    $definition = $uiAst.Find({ param($ast)
        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $name
    }, $false)
    if ($null -eq $definition) { throw "Missing production function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

# Only these fake responses are available; no CLI, network, credentials or config access.
function Get-ArkCliVersion { return 'offline-fixture' }
function Invoke-ArkCliJson([string]$skillName, [string[]]$arguments) {
    $key = $arguments -join ' '
    [void]$script:arkCalls.Add($key)
    if (-not $script:arkResponses.ContainsKey($key)) { throw "Unexpected CLI call: $key" }
    $response = $script:arkResponses[$key]
    if ($response -is [Exception]) { throw $response }
    return ($response | ConvertFrom-Json)
}
function Reset-ArkFixture {
    $script:arkCalls = New-Object System.Collections.Generic.List[string]
    $script:arkResponses = @{
        'auth status --format json' = '{"logged_in":true}'
        'plans get --format json' = '{"plans":[{"key":"coding-plan"},{"key":"agent-plan"}]}'
        'usage plan --format json' = '{"items":[{"product":"coding-plan","periods":[{"label":"5h","percent":0}]}]}'
        'plans model-list --plan coding-plan --format json' = '{"selected_model_id":"flash-20260901","models":[{"model_id":"flash-20260901","output_name":"deepseek-v4-flash"},{"output_name":"auto"}]}'
    }
}
function Assert-Equal($actual, $expected) {
    if ($actual -cne $expected) { throw "Expected [$expected], got [$actual]" }
}
$script:passed = 0
$script:failures = @()
function Test-Case([string]$name, [scriptblock]$body) {
    try {
        & $body
        $script:passed++
        Write-Output "PASS: $name"
    } catch {
        $script:failures += "${name}: $($_.Exception.Message)"
        Write-Output "FAIL: $name - $($_.Exception.Message)"
    }
}

Test-Case 'Current model schema uses output_name and selected_model_id' {
    Reset-ArkFixture
    $data = Get-VolcengineDashboardData
    Assert-Equal ($data.LiveModelIds -join ',') 'deepseek-v4-flash,auto'
    Assert-Equal $data.Plans.Count 1
    Assert-Equal ([string]::IsNullOrEmpty($data.Models[0].Note)) $false
    Assert-Equal $data.Errors.Count 0
}
Test-Case 'Legacy model schema keeps the explicit latest alias' {
    Reset-ArkFixture
    $script:arkResponses['plans model-list --plan coding-plan --format json'] = '{"ark_latest_model_id":"legacy-model","models":[{"model_id":"legacy-model","is_ark_latest":true}]}'
    $data = Get-VolcengineDashboardData
    Assert-Equal ($data.LiveModelIds -join ',') 'legacy-model,ark-code-latest'
}
Test-Case 'Usage failure does not discard available models' {
    Reset-ArkFixture
    $script:arkResponses['usage plan --format json'] = [Exception]::new('fixture usage unavailable')
    $data = Get-VolcengineDashboardData
    Assert-Equal $data.LiveModelIds.Count 2
    Assert-Equal $data.Errors.Count 1
    Assert-Equal $data.UsageItems.Count 0
}
Test-Case 'Model failure does not discard usage' {
    Reset-ArkFixture
    $script:arkResponses['plans model-list --plan coding-plan --format json'] = [Exception]::new('fixture model unavailable')
    $data = Get-VolcengineDashboardData
    Assert-Equal $data.LiveModelIds.Count 0
    Assert-Equal $data.Errors.Count 1
    Assert-Equal $data.UsageItems.Count 1
}
Test-Case 'Logged-out status does not query plans or usage' {
    Reset-ArkFixture
    $script:arkResponses['auth status --format json'] = '{"logged_in":false}'
    $data = Get-VolcengineDashboardData
    Assert-Equal $data.LoggedIn $false
    Assert-Equal $data.LiveModelIds.Count 0
    Assert-Equal $script:arkCalls.Count 1
}
Test-Case 'Empty plans and models remain empty' {
    Reset-ArkFixture
    $script:arkResponses['plans get --format json'] = '{"plans":[]}'
    $data = Get-VolcengineDashboardData
    Assert-Equal $data.LiveModelIds.Count 0
    Assert-Equal $data.Plans.Count 0
}
Test-Case 'Personal and team models are deduplicated; empty IDs are ignored' {
    Reset-ArkFixture
    $script:arkResponses['plans get --format json'] = '{"plans":[{"key":"coding-plan"},{"key":"coding-plan-team"}]}'
    $script:arkResponses['plans model-list --plan coding-plan-team --format json'] = '{"models":[{"output_name":"auto","selected":true},{"model_id":"team-only"},{}]}'
    $data = Get-VolcengineDashboardData
    Assert-Equal ($data.LiveModelIds -join ',') 'deepseek-v4-flash,auto,team-only'
    Assert-Equal ([string]::IsNullOrEmpty($data.Models[2].Note)) $false
}
Test-Case 'Zero quota is distinct from missing quota' {
    $zero = Get-VolcengineUsageDisplay ('{"percent":0}' | ConvertFrom-Json)
    $missing = Get-VolcengineUsageDisplay ('{}' | ConvertFrom-Json)
    Assert-Equal ($zero -match '0%') $true
    Assert-Equal ($missing -match '0%') $false
    Assert-Equal ((Get-VolcengineUsageDisplay ('{"used":0,"total":100}' | ConvertFrom-Json)) -match '0 / 100') $true
}

# Exercise real ComboBox selection events without opening a form or starting services.
Add-Type -AssemblyName System.Windows.Forms
$openCodeProvider = 'opencode_go'
$volcengineProvider = 'volcengine_coding_plan'
$customApiProvider = 'custom_openai'
$authComboBox = New-Object System.Windows.Forms.ComboBox
$apiProviderComboBox = New-Object System.Windows.Forms.ComboBox
$modelComboBox = New-Object System.Windows.Forms.ComboBox
$reasoningEffortComboBox = New-Object System.Windows.Forms.ComboBox
$codexImageCheckBox = New-Object System.Windows.Forms.CheckBox
$authComboBox.Items.AddRange(@('api', 'codex', 'native'))
$apiProviderComboBox.Items.AddRange(@('opencode', 'volcengine', 'custom'))
$script:updatingApiProvider = $false
$script:codexModelsById = @{}
$script:lastCodexReasoningEffort = 'high'
function Set-ServiceStatusState { }
$selectionHandler = $uiAst.Find({ param($ast)
    $ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $ast.Expression.Extent.Text -eq '$modelComboBox' -and
    $ast.Member.Extent.Text -eq 'Add_SelectedIndexChanged'
}, $false)
if ($null -eq $selectionHandler) { throw 'Missing model selection handler' }
. ([scriptblock]::Create($selectionHandler.Extent.Text))
try {
    $modelComboBox.CreateControl()
    $reasoningEffortComboBox.CreateControl()
    Test-Case 'Volcengine refresh preserves selected model and max reasoning' {
        $script:updatingApiProvider = $true
        $authComboBox.SelectedIndex = 0
        $apiProviderComboBox.SelectedIndex = 1
        Update-ApiModelOptions @('deepseek-v4-flash', 'auto') 'deepseek-v4-flash'
        $modelComboBox.SelectedIndex = 0
        Update-ApiReasoningEfforts 'max'
        $script:updatingApiProvider = $false
        Set-VolcengineLiveModels @('deepseek-v4-flash', 'auto', 'team-only') (Get-Date)
        Assert-Equal $modelComboBox.Text 'deepseek-v4-flash'
        Assert-Equal (Get-SelectedApiReasoningEffort) 'max'
    }
    Test-Case 'Volcengine refresh keeps manually entered or absent model' {
        $modelComboBox.Text = 'manual-model'
        Set-VolcengineLiveModels @('auto') (Get-Date)
        Assert-Equal $modelComboBox.Text 'manual-model'
        Set-VolcengineLiveModels @() (Get-Date)
        Assert-Equal $modelComboBox.Text 'manual-model'
    }
    Test-Case 'Codex refresh preserves model and reasoning selection' {
        $authComboBox.SelectedIndex = 1
        $script:codexModelsById.Clear()
        $modelComboBox.Items.Clear()
        $modelComboBox.Text = 'test-model'
        $reasoningEffortComboBox.Items.Clear()
        [void]$reasoningEffortComboBox.Items.Add('high')
        $reasoningEffortComboBox.SelectedItem = 'high'
        $status = '{"authenticated":true,"planType":"pro","rateLimits":[],"usageSummary":null,"rateLimitsError":null,"usageError":null,"imageGenerationAvailable":false,"models":[{"id":"test-model","isDefault":true,"defaultReasoningEffort":"low","supportedReasoningEfforts":["low","high"]}]}' | ConvertFrom-Json
        Apply-CodexStatus $status
        Assert-Equal $modelComboBox.Text 'test-model'
        Assert-Equal $reasoningEffortComboBox.Text 'high'
    }
} finally {
    foreach ($control in @($authComboBox, $apiProviderComboBox, $modelComboBox, $reasoningEffortComboBox, $codexImageCheckBox)) {
        $control.Dispose()
    }
}
Write-Output "$script:passed passed; $($script:failures.Count) failed"
if ($script:failures.Count -gt 0) { throw ($script:failures -join [Environment]::NewLine) }
