param(
    [switch]$SkipBuild,
    [string]$BuildLabel = ""
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
    if (Test-Path -LiteralPath $localFlutter -PathType Leaf) {
        return $localFlutter
    }

    throw "Flutter не найден. Добавьте flutter\bin в PATH или установите Flutter в $env:USERPROFILE\flutter."
}

function Resolve-Dart([string]$FlutterPath) {
    $flutterBin = Split-Path -Parent $FlutterPath
    $flutterRoot = Split-Path -Parent $flutterBin
    $dartFromFlutter = Join-Path $flutterRoot "bin\cache\dart-sdk\bin\dart.exe"
    if (Test-Path -LiteralPath $dartFromFlutter -PathType Leaf) {
        return $dartFromFlutter
    }

    $fromPath = Get-Command dart -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    throw "Dart не найден. Один раз выполните flutter --version, чтобы Flutter подготовил встроенный Dart SDK."
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    Write-Host $Step
    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Step завершён с кодом $exitCode."
    }
}

$Flutter = Resolve-Flutter
$Dart = Resolve-Dart $Flutter

if ([string]::IsNullOrWhiteSpace($BuildLabel)) {
    $gitLabel = @(& git -C $RepoRoot rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0) {
        $BuildLabel = ($gitLabel | Out-String).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($BuildLabel)) {
        $BuildLabel = "local"
    }
}

Push-Location $FrontendDir
try {
    Invoke-CheckedCommand -Step "Получение зависимостей Flutter по pubspec.lock..." -FilePath $Flutter -Arguments @("pub", "get", "--enforce-lockfile")
    Invoke-CheckedCommand -Step "Проверка форматирования Dart без изменения файлов..." -FilePath $Dart -Arguments @("--suppress-analytics", "format", "--output=none", "--set-exit-if-changed", ".")
    Invoke-CheckedCommand -Step "Статический анализ Flutter..." -FilePath $Flutter -Arguments @("analyze")
    Invoke-CheckedCommand -Step "Запуск клиентских тестов..." -FilePath $Flutter -Arguments @("test")

    if ($SkipBuild) {
        Write-Host "Сборка Flutter Web пропущена по явному параметру."
    }
    else {
        Invoke-CheckedCommand -Step "Сборка Flutter Web с меткой $BuildLabel..." -FilePath $Flutter -Arguments @("build", "web", "--pwa-strategy=none", "--dart-define", "UMCLICK_BUILD_LABEL=$BuildLabel")
    }
}
finally {
    Pop-Location
}

Write-Host "Клиентские проверки завершены успешно."
