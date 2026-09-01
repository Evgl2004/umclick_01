param(
    [switch]$InstallBackend,
    [switch]$SkipFrontendBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DevScript = Join-Path $RepoRoot "dev.ps1"

if ($InstallBackend) {
    & $DevScript setup-python
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$arguments = @("test-all")
if ($SkipFrontendBuild) {
    $arguments += "-SkipFrontendBuild"
}

& $DevScript @arguments
exit $LASTEXITCODE
