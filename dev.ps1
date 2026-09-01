[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("setup-python", "doctor", "test-backend", "test-frontend", "test-all")]
    [string]$Command = "doctor",
    [switch]$Coverage,
    [switch]$SkipBuild,
    [switch]$SkipFrontendBuild,
    [string]$BuildLabel = "",
    [string]$Settings = "umclick.test_settings"
)

$script:SettingsWasProvided = $PSBoundParameters.ContainsKey("Settings")

$script:EnvironmentNames = @(
    "UMCLICK_TEST_DB_HOST",
    "UMCLICK_TEST_DB_PORT",
    "UMCLICK_TEST_DB_USER",
    "UMCLICK_TEST_DB_PASSWORD",
    "UMCLICK_TEST_DB_MAINTENANCE_NAME",
    "UMCLICK_TEST_DB_NAME",
    "DJANGO_SETTINGS_MODULE",
    "PYTHONUTF8",
    "PYTHONIOENCODING"
)
$script:SavedEnvironment = @{}
$callingEnvironment = [Environment]::GetEnvironmentVariables("Process")
foreach ($name in $script:EnvironmentNames) {
    $exists = $callingEnvironment.Contains($name)
    $script:SavedEnvironment[$name] = @{
        Exists = $exists
        Value = if ($exists) { [string]$callingEnvironment[$name] } else { $null }
    }
}
$script:SavedInputEncoding = [Console]::InputEncoding
$script:SavedOutputEncoding = [Console]::OutputEncoding
$script:SavedPowerShellOutputEncoding = $OutputEncoding

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:RepoRoot = $PSScriptRoot
$script:BackendDir = Join-Path $script:RepoRoot "backend"
$script:FrontendDir = Join-Path $script:RepoRoot "frontend"
$script:VenvDir = Join-Path $script:BackendDir ".venv"
$script:Python = Join-Path $script:VenvDir "Scripts\python.exe"
$script:Requirements = Join-Path $script:BackendDir "requirements-dev.txt"
$script:EnvironmentFile = Join-Path $script:RepoRoot ".env.test.local"
$script:RequiredDatabaseKeys = @(
    "UMCLICK_TEST_DB_HOST",
    "UMCLICK_TEST_DB_PORT",
    "UMCLICK_TEST_DB_USER",
    "UMCLICK_TEST_DB_PASSWORD",
    "UMCLICK_TEST_DB_MAINTENANCE_NAME",
    "UMCLICK_TEST_DB_NAME"
)

function Set-ProcessEncoding {
    [Console]::InputEncoding = $script:Utf8
    [Console]::OutputEncoding = $script:Utf8
    Set-Variable -Name OutputEncoding -Scope Script -Value $script:Utf8
    [Environment]::SetEnvironmentVariable("PYTHONUTF8", "1", "Process")
    [Environment]::SetEnvironmentVariable("PYTHONIOENCODING", "utf-8", "Process")
}

function Restore-CallerState {
    foreach ($name in $script:EnvironmentNames) {
        $saved = $script:SavedEnvironment[$name]
        if ($saved.Exists) {
            [Environment]::SetEnvironmentVariable($name, [string]$saved.Value, "Process")
        }
        else {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        }
    }
    [Console]::InputEncoding = $script:SavedInputEncoding
    [Console]::OutputEncoding = $script:SavedOutputEncoding
    Set-Variable -Name OutputEncoding -Scope Script -Value $script:SavedPowerShellOutputEncoding
}

function Write-SafeMessage {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][object]$Value,
        [System.ConsoleColor]$ForegroundColor
    )
    $message = [string]$Value
    $password = [Environment]::GetEnvironmentVariable("UMCLICK_TEST_DB_PASSWORD", "Process")
    if (-not [string]::IsNullOrEmpty($password)) {
        $message = $message.Replace($password, "[СКРЫТО]")
    }
    if ($PSBoundParameters.ContainsKey("ForegroundColor")) {
        Write-Host $message -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host $message
    }
}

function Throw-CommandFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )
    $exception = New-Object System.Exception("$Step завершился ошибкой: код $ExitCode.")
    $exception.Data["ExitCode"] = $ExitCode
    throw $exception
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    Write-SafeMessage $Step
    & $FilePath @Arguments 2>&1 | ForEach-Object { Write-SafeMessage ([string]$_) }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Throw-CommandFailure -Step $Step -ExitCode $exitCode
    }
}

function Invoke-PythonJson {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Step,
        [string[]]$Arguments = @()
    )
    $output = @(& $script:Python -B -X utf8 -c $Code @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        foreach ($line in $output) {
            Write-SafeMessage ([string]$line)
        }
        Throw-CommandFailure -Step $Step -ExitCode $exitCode
    }
    try {
        return (($output | Out-String).Trim() | ConvertFrom-Json)
    }
    catch {
        throw "$Step вернул неожиданный результат."
    }
}

function Assert-PowerShellVersion {
    $version = $PSVersionTable.PSVersion
    if (-not (($version.Major -eq 5 -and $version.Minor -ge 1) -or $version.Major -ge 7)) {
        throw "Требуется Windows PowerShell 5.1 или PowerShell 7 и новее. Обнаружена версия $version."
    }
    Write-SafeMessage "PowerShell: $version."
}

function Assert-ParameterContract {
    if ($Coverage -and $Command -ne "test-backend") {
        throw "Параметр -Coverage допустим только для test-backend."
    }
    if ($SkipBuild -and $Command -ne "test-frontend") {
        throw "Параметр -SkipBuild допустим только для test-frontend."
    }
    if ($SkipFrontendBuild -and $Command -ne "test-all") {
        throw "Параметр -SkipFrontendBuild допустим только для test-all."
    }
    if (-not [string]::IsNullOrWhiteSpace($BuildLabel) -and $Command -ne "test-frontend") {
        throw "Параметр -BuildLabel допустим только для test-frontend."
    }
    if ($Settings -notin @("umclick.test_settings", "umclick.stage_a_checks")) {
        throw "Параметр -Settings допускает только umclick.test_settings или umclick.stage_a_checks."
    }
    if ($script:SettingsWasProvided -and $Command -ne "test-backend") {
        throw "Параметр -Settings допустим только для test-backend."
    }
}

function Assert-PythonRuntime {
    if (-not (Test-Path -LiteralPath $script:VenvDir -PathType Container)) {
        throw "Не найдено backend/.venv. Выполните .\dev.ps1 setup-python."
    }
    if (-not (Test-Path -LiteralPath $script:Python -PathType Leaf)) {
        throw "backend/.venv существует, но Scripts/python.exe отсутствует. Окружение не пересоздавалось; исправьте его вручную."
    }
    $probe = @'
import json
import platform
import sys
print(json.dumps({'version': platform.python_version(), 'executable': sys.executable}))
'@
    $result = Invoke-PythonJson -Code $probe -Step "Проверка Python в backend/.venv"
    $version = [Version]$result.version
    if ($version.Major -ne 3 -or $version.Minor -notin @(12, 13)) {
        throw "backend/.venv использует Python $($result.version); поддерживаются Python 3.12.x и 3.13.x. Окружение не пересоздавалось."
    }
    Write-SafeMessage "Python: $($result.version), окружение: backend/.venv."
    return $result
}

function Assert-PythonPackages {
    $probe = @'
import json
from importlib import metadata

imports = {
    'Django': 'django',
    'djangorestframework': 'rest_framework',
    'channels': 'channels',
    'daphne': 'daphne',
    'psycopg': 'psycopg',
    'celery': 'celery',
    'coverage': 'coverage',
}
versions = {}
for distribution, module_name in imports.items():
    __import__(module_name)
    versions[distribution] = metadata.version(distribution)
print(json.dumps(versions))
'@
    $result = Invoke-PythonJson -Code $probe -Step "Проверка обязательных пакетов Python"
    Write-SafeMessage "Пакеты Python: Django $($result.Django), DRF $($result.djangorestframework), Channels $($result.channels), Daphne $($result.daphne), psycopg $($result.psycopg), Celery $($result.celery), coverage $($result.coverage)."
    return $result
}

function Resolve-BasePython {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        foreach ($minor in @(12, 13)) {
            $path = Join-Path $env:LOCALAPPDATA "Programs\Python\Python3$minor\python.exe"
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $candidates += [PSCustomObject]@{ Path = $path; Prefix = @() }
            }
        }
    }
    foreach ($name in @("python", "python3")) {
        $commandInfo = Get-Command $name -ErrorAction SilentlyContinue
        if ($commandInfo) {
            $candidates += [PSCustomObject]@{ Path = $commandInfo.Source; Prefix = @() }
        }
    }
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        $candidates += [PSCustomObject]@{ Path = $launcher.Source; Prefix = @("-3.12") }
        $candidates += [PSCustomObject]@{ Path = $launcher.Source; Prefix = @("-3.13") }
    }
    foreach ($candidate in $candidates) {
        $output = @(& $candidate.Path @($candidate.Prefix) -B -X utf8 -c "import platform; print(platform.python_version())" 2>&1)
        if ($LASTEXITCODE -ne 0) {
            continue
        }
        try {
            $version = [Version](($output | Out-String).Trim())
        }
        catch {
            continue
        }
        if ($version.Major -eq 3 -and $version.Minor -in @(12, 13)) {
            return [PSCustomObject]@{ Path = $candidate.Path; Prefix = $candidate.Prefix; Version = $version.ToString() }
        }
    }
    throw "Не найден совместимый Python 3.12 или 3.13. Сценарий не устанавливает Python."
}

function Read-TestEnvironment {
    param([Parameter(Mandatory = $true)][string]$SettingsModule)
    if (-not (Test-Path -LiteralPath $script:EnvironmentFile -PathType Leaf)) {
        throw "Не найден .env.test.local. Скопируйте .env.test.example и заполните локальные значения вручную."
    }
    $values = @{}
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines($script:EnvironmentFile, [Text.Encoding]::UTF8)) {
        $lineNumber += 1
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
            continue
        }
        if ($line -notmatch '^\s*([A-Z][A-Z0-9_]*)\s*=(.*)$') {
            throw "Некорректная строка $lineNumber в .env.test.local. Ожидается КЛЮЧ=значение."
        }
        $key = $Matches[1]
        if ($key -notin $script:RequiredDatabaseKeys) {
            throw "Недопустимый ключ $key в .env.test.local. Разрешены только шесть UMCLICK_TEST_DB_*."
        }
        if ($values.ContainsKey($key)) {
            throw "Ключ $key повторяется в .env.test.local."
        }
        $value = $Matches[2].Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Ключ $key в .env.test.local не имеет значения."
        }
        $values[$key] = $value
    }
    $missing = @($script:RequiredDatabaseKeys | Where-Object { -not $values.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "В .env.test.local отсутствуют обязательные переменные: $($missing -join ', ')."
    }
    $hostName = $values["UMCLICK_TEST_DB_HOST"].ToLowerInvariant()
    if ($hostName -notin @("127.0.0.1", "localhost", "::1")) {
        throw "UMCLICK_TEST_DB_HOST должен быть loopback-адресом: 127.0.0.1, localhost или ::1."
    }
    $port = 0
    if (-not [int]::TryParse($values["UMCLICK_TEST_DB_PORT"], [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "UMCLICK_TEST_DB_PORT должен быть целым числом от 1 до 65535."
    }
    foreach ($key in @("UMCLICK_TEST_DB_USER", "UMCLICK_TEST_DB_MAINTENANCE_NAME")) {
        if ($values[$key] -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "$key содержит недопустимые символы."
        }
    }
    if ($values["UMCLICK_TEST_DB_NAME"] -notmatch '^test_umclick_[a-z0-9_]+$') {
        throw "UMCLICK_TEST_DB_NAME должен соответствовать шаблону test_umclick_*."
    }
    if ($values["UMCLICK_TEST_DB_NAME"] -ceq $values["UMCLICK_TEST_DB_MAINTENANCE_NAME"]) {
        throw "Служебная и временная тестовая базы не могут совпадать."
    }
    $values["UMCLICK_TEST_DB_HOST"] = $hostName
    $values["UMCLICK_TEST_DB_PORT"] = $port.ToString()
    foreach ($key in $script:RequiredDatabaseKeys) {
        [Environment]::SetEnvironmentVariable($key, [string]$values[$key], "Process")
    }
    [Environment]::SetEnvironmentVariable("DJANGO_SETTINGS_MODULE", $SettingsModule, "Process")
    Write-SafeMessage "Параметры локального PostgreSQL загружены из .env.test.local; значения не выводятся."
    return $values
}

function Assert-TestSettings {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsModule,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )
    $probe = @'
import importlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
pgpassword_before = os.environ.get('PGPASSWORD')
settings = importlib.import_module(sys.argv[2])
database = settings.DATABASES['default']
if database.get('PASSWORD') != os.environ['UMCLICK_TEST_DB_PASSWORD']:
    raise RuntimeError('Пароль не передан через DATABASES.')
if os.environ.get('PGPASSWORD') != pgpassword_before:
    raise RuntimeError('Модуль настроек изменил PGPASSWORD.')
print(json.dumps({
    'engine': database.get('ENGINE'),
    'name': database.get('NAME'),
    'test_name': database.get('TEST', {}).get('NAME'),
    'channel_backend': settings.CHANNEL_LAYERS['default'].get('BACKEND'),
    'celery_eager': settings.CELERY_TASK_ALWAYS_EAGER,
}))
'@
    $result = Invoke-PythonJson -Code $probe -Step "Импорт $SettingsModule" -Arguments @($script:BackendDir, $SettingsModule)
    if ($result.engine -cne "django.db.backends.postgresql") {
        throw "$SettingsModule должен использовать PostgreSQL."
    }
    if ($result.name -cne $Values["UMCLICK_TEST_DB_MAINTENANCE_NAME"] -or $result.test_name -cne $Values["UMCLICK_TEST_DB_NAME"]) {
        throw "$SettingsModule вернул неожиданные NAME или TEST.NAME."
    }
    if ($result.channel_backend -cne "channels.layers.InMemoryChannelLayer" -or -not $result.celery_eager) {
        throw "$SettingsModule должен использовать Channels и фоновые задачи в памяти."
    }
    Write-SafeMessage "Модуль $SettingsModule успешно импортирован; PostgreSQL и настройки памяти подтверждены."
}

function Assert-PostgreSql {
    param([Parameter(Mandatory = $true)][hashtable]$Values)
    $probe = @'
import json
import os
import sys

import psycopg

try:
    with psycopg.connect(
        host=os.environ['UMCLICK_TEST_DB_HOST'],
        port=os.environ['UMCLICK_TEST_DB_PORT'],
        user=os.environ['UMCLICK_TEST_DB_USER'],
        password=os.environ['UMCLICK_TEST_DB_PASSWORD'],
        dbname=os.environ['UMCLICK_TEST_DB_MAINTENANCE_NAME'],
        connect_timeout=5,
        autocommit=True,
        options='-c default_transaction_read_only=on',
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                '''SELECT inet_server_addr()::text, inet_server_port(), current_database(), current_user, current_setting('server_version'), current_setting('server_version_num')::integer'''
            )
            server = cursor.fetchone()
            cursor.execute(
                'SELECT r.rolcanlogin, r.rolcreatedb, r.rolsuper, r.rolcreaterole, r.rolreplication, r.rolbypassrls, d.datdba = r.oid FROM pg_roles r JOIN pg_database d ON d.datname = current_database() WHERE r.rolname = current_user'
            )
            role = cursor.fetchone()
    print(json.dumps({'server': server, 'role': role}))
except Exception as error:
    print(f'Не удалось выполнить читающую диагностику PostgreSQL: {error}', file=sys.stderr)
    raise SystemExit(21)
'@
    $result = Invoke-PythonJson -Code $probe -Step "Диагностика PostgreSQL"
    $server = @($result.server)
    $role = @($result.role)
    if ($server.Count -ne 6 -or $role.Count -ne 7) {
        throw "PostgreSQL вернул неполный диагностический результат."
    }
    if ($server[0] -notin @("127.0.0.1", "::1")) {
        throw "PostgreSQL подтвердил соединение не через loopback-адрес."
    }
    if ([string]$server[1] -ne $Values["UMCLICK_TEST_DB_PORT"] -or $server[2] -cne $Values["UMCLICK_TEST_DB_MAINTENANCE_NAME"] -or $server[3] -cne $Values["UMCLICK_TEST_DB_USER"]) {
        throw "Фактические порт, служебная база или роль PostgreSQL не совпадают с .env.test.local."
    }
    $serverVersionNumber = 0
    if (-not [int]::TryParse([string]$server[5], [ref]$serverVersionNumber)) {
        throw "PostgreSQL не вернул корректный server_version_num."
    }
    $major = [Math]::Floor($serverVersionNumber / 10000)
    if ($major -notin @(16, 17)) {
        throw "Поддерживаются только PostgreSQL 16 и 17; сервер сообщил версию $major."
    }
    if (-not $role[0] -or -not $role[1]) {
        throw "Тестовой роли PostgreSQL требуются LOGIN и CREATEDB."
    }
    if ($role[2] -or $role[3] -or $role[4] -or $role[5]) {
        throw "Тестовая роль не должна иметь SUPERUSER, CREATEROLE, REPLICATION или BYPASSRLS."
    }
    if ($role[6]) {
        throw "Тестовая роль не должна владеть служебной базой."
    }
    Write-SafeMessage "PostgreSQL $($server[4]): loopback, версия 16/17 и минимальные права роли подтверждены."
}

function Resolve-FlutterTools {
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCommand) {
        $flutterPath = $flutterCommand.Source
    }
    else {
        $flutterPath = Join-Path $env:USERPROFILE "flutter\bin\flutter.bat"
    }
    if (-not (Test-Path -LiteralPath $flutterPath -PathType Leaf)) {
        throw "Flutter не найден. Добавьте flutter\bin в PATH или установите Flutter в каталог пользователя."
    }
    $flutterRoot = Split-Path -Parent (Split-Path -Parent $flutterPath)
    $dartPath = Join-Path $flutterRoot "bin\cache\dart-sdk\bin\dart.exe"
    $flutterVersionFile = Join-Path $flutterRoot "bin\cache\flutter.version.json"
    $dartVersionFile = Join-Path $flutterRoot "bin\cache\dart-sdk\version"
    if (-not (Test-Path -LiteralPath $dartPath -PathType Leaf) -or -not (Test-Path -LiteralPath $flutterVersionFile -PathType Leaf) -or -not (Test-Path -LiteralPath $dartVersionFile -PathType Leaf)) {
        throw "Flutter SDK не подготовлен полностью: отсутствуют Dart или файлы версий."
    }
    try {
        $flutterVersion = (Get-Content -LiteralPath $flutterVersionFile -Raw -Encoding UTF8 | ConvertFrom-Json).flutterVersion
        $dartVersion = (Get-Content -LiteralPath $dartVersionFile -Raw -Encoding UTF8).Trim()
    }
    catch {
        throw "Не удалось прочитать локальные версии Flutter и Dart."
    }
    Write-SafeMessage "Flutter: $flutterVersion; Dart: $dartVersion."
    return [PSCustomObject]@{ Flutter = $flutterPath; Dart = $dartPath }
}

function Resolve-BuildLabel {
    if (-not [string]::IsNullOrWhiteSpace($BuildLabel)) {
        return $BuildLabel
    }
    $output = @(& git -C $script:RepoRoot rev-parse --short HEAD 2>&1)
    if ($LASTEXITCODE -eq 0) {
        $label = ($output | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($label)) {
            return $label
        }
    }
    return "local"
}

function Invoke-SetupPython {
    if (-not (Test-Path -LiteralPath $script:Requirements -PathType Leaf)) {
        throw "Не найден backend/requirements-dev.txt."
    }
    if (Test-Path -LiteralPath $script:VenvDir -PathType Container) {
        Write-SafeMessage "Используется существующее backend/.venv; оно не удаляется и не пересоздаётся."
        $null = Assert-PythonRuntime
    }
    elseif (Test-Path -LiteralPath $script:VenvDir) {
        throw "Путь backend/.venv существует, но не является каталогом; автоматическое исправление запрещено."
    }
    else {
        $basePython = Resolve-BasePython
        $arguments = @($basePython.Prefix) + @("-m", "venv", $script:VenvDir)
        Invoke-ExternalCommand -Step "Создание backend/.venv через Python $($basePython.Version)..." -FilePath $basePython.Path -Arguments $arguments
        $null = Assert-PythonRuntime
    }
    Invoke-ExternalCommand -Step "Установка backend/requirements-dev.txt..." -FilePath $script:Python -Arguments @("-m", "pip", "install", "--requirement", $script:Requirements)
    $null = Assert-PythonPackages
    Write-SafeMessage "Python-окружение подготовлено."
}

function Invoke-Doctor {
    $null = Assert-PythonRuntime
    $null = Assert-PythonPackages
    $null = Resolve-FlutterTools
    $values = Read-TestEnvironment -SettingsModule "umclick.test_settings"
    Assert-TestSettings -SettingsModule "umclick.test_settings" -Values $values
    Assert-PostgreSql -Values $values
    Write-SafeMessage "Диагностика завершена успешно; файлы и внешние системы не изменялись."
}

function Invoke-BackendTests {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsModule,
        [switch]$WithCoverage
    )
    $null = Assert-PythonRuntime
    $null = Assert-PythonPackages
    $values = Read-TestEnvironment -SettingsModule $SettingsModule
    Assert-TestSettings -SettingsModule $SettingsModule -Values $values
    Push-Location $script:BackendDir
    try {
        Invoke-ExternalCommand -Step "Проверка отсутствия забытых миграций..." -FilePath $script:Python -Arguments @("manage.py", "makemigrations", "--check", "--dry-run", "--settings=$SettingsModule")
        Invoke-ExternalCommand -Step "Системная проверка Django..." -FilePath $script:Python -Arguments @("manage.py", "check", "--settings=$SettingsModule")
        if ($WithCoverage) {
            Invoke-ExternalCommand -Step "Запуск серверных тестов с покрытием..." -FilePath $script:Python -Arguments @("-m", "coverage", "run", "--rcfile=.coveragerc", "manage.py", "test", "--settings=$SettingsModule", "--noinput")
            Invoke-ExternalCommand -Step "Текстовый отчёт покрытия..." -FilePath $script:Python -Arguments @("-m", "coverage", "report", "--rcfile=.coveragerc")
            Invoke-ExternalCommand -Step "HTML-отчёт покрытия..." -FilePath $script:Python -Arguments @("-m", "coverage", "html", "--rcfile=.coveragerc")
            Write-SafeMessage "HTML-отчёт: backend/htmlcov/index.html."
        }
        else {
            Invoke-ExternalCommand -Step "Запуск полного набора серверных тестов..." -FilePath $script:Python -Arguments @("manage.py", "test", "--settings=$SettingsModule", "--noinput")
        }
    }
    finally {
        Pop-Location
    }
    Write-SafeMessage "Серверные проверки завершены успешно."
}

function Invoke-FrontendTests {
    param(
        [switch]$WithoutBuild,
        [string]$RequestedBuildLabel = ""
    )
    $tools = Resolve-FlutterTools
    Push-Location $script:FrontendDir
    try {
        Invoke-ExternalCommand -Step "Получение зависимостей Flutter по pubspec.lock..." -FilePath $tools.Flutter -Arguments @("pub", "get", "--enforce-lockfile")
        Invoke-ExternalCommand -Step "Проверка форматирования Dart без изменения файлов..." -FilePath $tools.Dart -Arguments @("format", "--output=none", "--set-exit-if-changed", ".")
        Invoke-ExternalCommand -Step "Статический анализ Flutter..." -FilePath $tools.Flutter -Arguments @("analyze")
        Invoke-ExternalCommand -Step "Запуск клиентских тестов..." -FilePath $tools.Flutter -Arguments @("test")
        if ($WithoutBuild) {
            Write-SafeMessage "Сборка Flutter Web пропущена по явному параметру."
        }
        else {
            $label = if ([string]::IsNullOrWhiteSpace($RequestedBuildLabel)) { Resolve-BuildLabel } else { $RequestedBuildLabel }
            Invoke-ExternalCommand -Step "Сборка Flutter Web..." -FilePath $tools.Flutter -Arguments @("build", "web", "--pwa-strategy=none", "--dart-define", "UMCLICK_BUILD_LABEL=$label")
        }
    }
    finally {
        Pop-Location
    }
    Write-SafeMessage "Клиентские проверки завершены успешно."
}

$exitCode = 0
try {
    Set-ProcessEncoding
    Assert-ParameterContract
    Assert-PowerShellVersion
    switch ($Command) {
        "setup-python" { Invoke-SetupPython }
        "doctor" { Invoke-Doctor }
        "test-backend" { Invoke-BackendTests -SettingsModule $Settings -WithCoverage:$Coverage }
        "test-frontend" { Invoke-FrontendTests -WithoutBuild:$SkipBuild -RequestedBuildLabel $BuildLabel }
        "test-all" {
            Invoke-BackendTests -SettingsModule "umclick.test_settings"
            Invoke-FrontendTests -WithoutBuild:$SkipFrontendBuild
            Write-SafeMessage "Все локальные проверки завершены успешно."
        }
    }
}
catch {
    $exitCode = 1
    if ($_.Exception.Data.Contains("ExitCode")) {
        $exitCode = [int]$_.Exception.Data["ExitCode"]
    }
    Write-SafeMessage "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    Write-SafeMessage "Автоматическая очистка не выполнялась; возможные изменения ограничены завершившейся внешней командой." -ForegroundColor Yellow
}
finally {
    try {
        Restore-CallerState
    }
    catch {
        Write-Host "Ошибка: не удалось полностью восстановить окружение вызывающего PowerShell: $($_.Exception.Message)" -ForegroundColor Red
        if ($exitCode -eq 0) {
            $exitCode = 1
        }
    }
}

exit $exitCode
