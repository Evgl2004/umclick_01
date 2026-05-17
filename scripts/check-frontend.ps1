param(
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$FrontendDir = Join-Path $RepoRoot "frontend"

function Resolve-Flutter {
    $fromPath = Get-Command flutter -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    $localFlutter = Join-Path $env:USERPROFILE "flutter\bin\flutter.bat"
    if (Test-Path -LiteralPath $localFlutter) {
        return $localFlutter
    }

    throw "Flutter was not found. Add flutter\bin to PATH or install it under $env:USERPROFILE\flutter."
}

function Resolve-Dart([string]$FlutterPath) {
    $flutterBin = Split-Path -Parent $FlutterPath
    $flutterRoot = Split-Path -Parent $flutterBin
    $dartFromFlutter = Join-Path $flutterRoot "bin\cache\dart-sdk\bin\dart.exe"
    if (Test-Path -LiteralPath $dartFromFlutter) {
        return $dartFromFlutter
    }

    $fromPath = Get-Command dart -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    throw "Dart was not found. Run flutter --version once so Flutter can prepare the bundled Dart SDK."
}

$Flutter = Resolve-Flutter
$Dart = Resolve-Dart $Flutter

Push-Location $FrontendDir
try {
    Write-Host "Resolving Flutter dependencies..."
    & $Flutter pub get

    Write-Host "Checking Dart formatting..."
    & $Dart format --set-exit-if-changed .

    Write-Host "Running flutter analyze..."
    & $Flutter analyze

    Write-Host "Running frontend tests..."
    & $Flutter test

    if (-not $SkipBuild) {
        Write-Host "Building Flutter Web..."
        & $Flutter build web
    }
}
finally {
    Pop-Location
}
