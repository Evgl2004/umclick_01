param(
    [switch]$InstallBackend,
    [switch]$SkipFrontendBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "Running backend checks..."
& (Join-Path $PSScriptRoot "check-backend.ps1") -Install:$InstallBackend

Write-Host "Running frontend checks..."
& (Join-Path $PSScriptRoot "check-frontend.ps1") -SkipBuild:$SkipFrontendBuild

Write-Host "All local checks passed."
