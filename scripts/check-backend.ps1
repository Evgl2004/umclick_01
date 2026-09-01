param(
    [switch]$Install,
    [string]$Settings = "umclick.settings"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackendDir = Join-Path $RepoRoot "backend"
$Python = Join-Path $BackendDir ".venv\Scripts\python.exe"
$Requirements = Join-Path $BackendDir "requirements.txt"

if (-not (Test-Path -LiteralPath $Python)) {
    throw "Не найдено окружение серверной части. Создайте его: python -m venv backend\.venv"
}

if ($Install) {
    Write-Host "Установка зависимостей серверной части..."
    & $Python -m pip install --upgrade pip
    if ($LASTEXITCODE -ne 0) { throw "Не удалось обновить установщик зависимостей: код $LASTEXITCODE" }
    & $Python -m pip install -r $Requirements
    if ($LASTEXITCODE -ne 0) { throw "Не удалось установить зависимости: код $LASTEXITCODE" }
}

Push-Location $BackendDir
try {
    Write-Host "Проверка миграций Django..."
    & $Python manage.py makemigrations --check --dry-run --settings=$Settings
    if ($LASTEXITCODE -ne 0) { throw "Проверка миграций завершилась ошибкой: код $LASTEXITCODE" }

    Write-Host "Запуск серверных проверок..."
    & $Python manage.py test --noinput --settings=$Settings
    if ($LASTEXITCODE -ne 0) { throw "Серверные проверки завершились ошибкой: код $LASTEXITCODE" }
}
finally {
    Pop-Location
}
