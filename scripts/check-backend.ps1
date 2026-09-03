param(
    [switch]$Coverage,
    [string]$Settings = "umclick.test_settings"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackendDir = Join-Path $RepoRoot "backend"
$EnvironmentFile = Join-Path $RepoRoot ".env.test.local"
$SitePackages = Join-Path $BackendDir ".venv\Lib\site-packages"
$VenvPython = Join-Path $BackendDir ".venv\Scripts\python.exe"
$PgAdminPython = "C:\Program Files\PostgreSQL\17\pgAdmin 4\python\python.exe"
$RequiredDatabaseKeys = @(
    "UMCLICK_TEST_DB_HOST",
    "UMCLICK_TEST_DB_PORT",
    "UMCLICK_TEST_DB_USER",
    "UMCLICK_TEST_DB_PASSWORD",
    "UMCLICK_TEST_DB_NAME"
)
$ManagedEnvironmentKeys = $RequiredDatabaseKeys + @(
    "DJANGO_SETTINGS_MODULE",
    "PYTHONUTF8",
    "PYTHONIOENCODING",
    "PYTHONDONTWRITEBYTECODE"
)
$PythonBootstrap = @'
import runpy
import os
import sys

site_packages, backend_dir, target_type, target, *arguments = sys.argv[1:]
runtime_site_packages = os.path.normcase(
    os.path.normpath(os.path.join(sys.base_prefix, 'Lib', 'site-packages'))
)
sys.path[:] = [
    path
    for path in sys.path
    if os.path.normcase(os.path.normpath(path)) != runtime_site_packages
]
sys.path.insert(0, backend_dir)
sys.path.insert(0, site_packages)
sys.argv = [target, *arguments]
if target_type == 'script':
    runpy.run_path(target, run_name='__main__')
else:
    runpy.run_module(target, run_name='__main__', alter_sys=True)
'@
$DatabaseSafetyCheck = @'
import os

from django.db import connections

expected_database = os.environ['UMCLICK_TEST_DB_NAME']
expected_user = os.environ['UMCLICK_TEST_DB_USER']
connection = connections['default']
try:
    with connection.cursor() as cursor:
        cursor.execute(
            '''
            SELECT
                current_database(),
                current_user,
                pg_get_userbyid(d.datdba),
                r.rolsuper,
                r.rolcreatedb,
                r.rolcreaterole,
                r.rolreplication,
                r.rolbypassrls
            FROM pg_catalog.pg_database AS d
            JOIN pg_catalog.pg_roles AS r ON r.rolname = current_user
            WHERE d.datname = current_database()
            ''',
        )
        database_state = cursor.fetchone()
finally:
    connection.close()

if database_state is None:
    raise SystemExit('Не удалось определить состояние постоянной тестовой базы.')

actual_database, actual_user, database_owner, *dangerous_privileges = database_state
if actual_database != expected_database:
    raise SystemExit('Подключение установлено не к указанной постоянной тестовой базе.')
if actual_user != expected_user:
    raise SystemExit('Подключение установлено не от имени указанной тестовой роли.')
if database_owner != actual_user:
    raise SystemExit('Тестовая роль не является владельцем постоянной тестовой базы.')
if any(dangerous_privileges):
    raise SystemExit(
        'Тестовая роль имеет запрещённые административные права PostgreSQL.'
    )
'@

if ($Settings -notin @("umclick.test_settings", "umclick.stage_a_checks")) {
    throw "Параметр -Settings допускает только umclick.test_settings или umclick.stage_a_checks."
}
if (-not (Test-Path -LiteralPath $SitePackages -PathType Container)) {
    throw "Не найден backend/.venv/Lib/site-packages с зависимостями серверной части."
}

if (Test-Path -LiteralPath $PgAdminPython -PathType Leaf) {
    $Python = $PgAdminPython
}
elseif (Test-Path -LiteralPath $VenvPython -PathType Leaf) {
    $Python = $VenvPython
}
else {
    throw "Не найден рабочий Python: отсутствуют Python pgAdmin и backend/.venv/Scripts/python.exe."
}

function Import-TestEnvironment {
    if (-not (Test-Path -LiteralPath $EnvironmentFile -PathType Leaf)) {
        throw "Не найден .env.test.local. Скопируйте .env.test.example и заполните локальные значения."
    }

    $values = @{}
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines($EnvironmentFile, [Text.Encoding]::UTF8)) {
        $lineNumber += 1
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
            continue
        }
        if ($line -notmatch '^\s*([A-Z][A-Z0-9_]*)\s*=(.*)$') {
            throw "Некорректная строка $lineNumber в .env.test.local. Ожидается КЛЮЧ=значение."
        }

        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($key -notin $RequiredDatabaseKeys) {
            throw "Недопустимый ключ $key в .env.test.local."
        }
        if ($values.ContainsKey($key)) {
            throw "Ключ $key повторяется в .env.test.local."
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Ключ $key в .env.test.local не имеет значения."
        }
        $values[$key] = $value
    }

    $missing = @($RequiredDatabaseKeys | Where-Object { -not $values.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "В .env.test.local отсутствуют обязательные переменные: $($missing -join ', ')."
    }

    foreach ($key in $RequiredDatabaseKeys) {
        [Environment]::SetEnvironmentVariable($key, [string]$values[$key], "Process")
    }
}

function Write-SafeOutput {
    param([AllowEmptyString()][object]$Value)

    $message = [string]$Value
    $password = [Environment]::GetEnvironmentVariable("UMCLICK_TEST_DB_PASSWORD", "Process")
    if (-not [string]::IsNullOrEmpty($password)) {
        $message = $message.Replace($password, "[СКРЫТО]")
    }
    Write-Host $message
}

function Invoke-PythonCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][ValidateSet("script", "module")][string]$TargetType,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    Write-Host $Step
    $savedErrorActionPreference = $ErrorActionPreference
    $exitCode = $null
    $invocationError = $null
    try {
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = $null
        try {
            & $Python -B -X utf8 -c $PythonBootstrap $SitePackages $BackendDir $TargetType $Target @Arguments 2>&1 | ForEach-Object { Write-SafeOutput $_ }
            $exitCode = $global:LASTEXITCODE
        }
        catch {
            $invocationError = $_
        }
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    if ($null -ne $invocationError) {
        throw "${Step}: не удалось запустить Python или обработать его вывод: $($invocationError.Exception.Message)"
    }
    if ($null -eq $exitCode) {
        throw "${Step}: не удалось запустить Python: процесс не вернул код завершения."
    }
    if ($exitCode -ne 0) {
        throw "$Step завершён с кодом $exitCode."
    }
}

$savedEnvironment = @{}
foreach ($key in $ManagedEnvironmentKeys) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
}

try {
    Import-TestEnvironment
    [Environment]::SetEnvironmentVariable("DJANGO_SETTINGS_MODULE", $Settings, "Process")
    [Environment]::SetEnvironmentVariable("PYTHONUTF8", "1", "Process")
    [Environment]::SetEnvironmentVariable("PYTHONIOENCODING", "utf-8", "Process")
    [Environment]::SetEnvironmentVariable("PYTHONDONTWRITEBYTECODE", "1", "Process")

    Push-Location $BackendDir
    try {
        Invoke-PythonCheck -Step "Проверка конфигурации Django..." -TargetType "script" -Target "manage.py" -Arguments @("check", "--settings=$Settings")
        Invoke-PythonCheck -Step "Проверка отсутствия забытых миграций..." -TargetType "script" -Target "manage.py" -Arguments @("makemigrations", "--check", "--dry-run", "--settings=$Settings")
        Invoke-PythonCheck -Step "Проверка безопасности постоянной тестовой базы..." -TargetType "script" -Target "manage.py" -Arguments @("shell", "--settings=$Settings", "-c", $DatabaseSafetyCheck)
        if ($Coverage) {
            Invoke-PythonCheck -Step "Запуск серверных тестов с покрытием..." -TargetType "module" -Target "coverage" -Arguments @("run", "--rcfile=.coveragerc", "manage.py", "test", "--settings=$Settings", "--noinput", "--keepdb")
            Invoke-PythonCheck -Step "Текстовый отчёт покрытия..." -TargetType "module" -Target "coverage" -Arguments @("report", "--rcfile=.coveragerc")
            Invoke-PythonCheck -Step "HTML-отчёт покрытия..." -TargetType "module" -Target "coverage" -Arguments @("html", "--rcfile=.coveragerc")
            Write-Host "HTML-отчёт: backend/htmlcov/index.html."
        }
        else {
            Invoke-PythonCheck -Step "Запуск полного набора серверных тестов..." -TargetType "script" -Target "manage.py" -Arguments @("test", "--settings=$Settings", "--noinput", "--keepdb")
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    foreach ($key in $ManagedEnvironmentKeys) {
        if ($null -eq $savedEnvironment[$key]) {
            Remove-Item -LiteralPath ("Env:" + $key) -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], "Process")
        }
    }
}

Write-Host "Серверные проверки завершены успешно."
