param(
    [switch]$Install
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackendDir = Join-Path $RepoRoot "backend"
$Python = Join-Path $BackendDir ".venv\Scripts\python.exe"
$Requirements = Join-Path $BackendDir "requirements.txt"

if (-not (Test-Path -LiteralPath $Python)) {
    throw "Backend venv was not found. Create it first: python -m venv backend\.venv"
}

if ($Install) {
    Write-Host "Installing backend dependencies..."
    & $Python -m pip install --upgrade pip
    & $Python -m pip install -r $Requirements
}

Push-Location $BackendDir
try {
    Write-Host "Checking Django migrations..."
    & $Python manage.py makemigrations --check --dry-run

    Write-Host "Running backend tests..."
    & $Python manage.py test
}
finally {
    Pop-Location
}
