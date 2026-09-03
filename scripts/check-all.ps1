param(
    [switch]$Coverage,
    [switch]$SkipFrontendBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$backendSucceeded = $false
$frontendSucceeded = $false

Write-Host "Запуск серверных проверок..."
try {
    & (Join-Path $PSScriptRoot "check-backend.ps1") -Coverage:$Coverage
    $backendSucceeded = $true
}
catch {
    Write-Host ("Ошибка серверной проверки: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host "Запуск клиентских проверок..."
try {
    & (Join-Path $PSScriptRoot "check-frontend.ps1") -SkipBuild:$SkipFrontendBuild
    $frontendSucceeded = $true
}
catch {
    Write-Host ("Ошибка клиентской проверки: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host ""
Write-Host "Итоговая сводка:"
Write-Host ("Серверная проверка: {0}" -f $(if ($backendSucceeded) { "успешно" } else { "ошибка" }))
Write-Host ("Клиентская проверка: {0}" -f $(if ($frontendSucceeded) { "успешно" } else { "ошибка" }))

if ($backendSucceeded -and $frontendSucceeded) {
    Write-Host "Все локальные проверки завершены успешно."
    exit 0
}

exit 1
