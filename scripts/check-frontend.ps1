param(
    [switch]$SkipBuild,
    [string]$BuildLabel = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DevScript = Join-Path $RepoRoot "dev.ps1"
$arguments = @("test-frontend")
if ($SkipBuild) {
    $arguments += "-SkipBuild"
}
if (-not [string]::IsNullOrWhiteSpace($BuildLabel)) {
    $arguments += @("-BuildLabel", $BuildLabel)
}

& $DevScript @arguments
exit $LASTEXITCODE
