param(
    [switch]$Install,
    [string]$Settings = "umclick.test_settings"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DevScript = Join-Path $RepoRoot "dev.ps1"

if ($Settings -notin @("umclick.test_settings", "umclick.stage_a_checks")) {
    Write-Host "Ошибка: -Settings допускает только umclick.test_settings или совместимое имя umclick.stage_a_checks." -ForegroundColor Red
    exit 1
}

if ($Install) {
    & $DevScript setup-python
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

& $DevScript test-backend -Settings $Settings
exit $LASTEXITCODE
