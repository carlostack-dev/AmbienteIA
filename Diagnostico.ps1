#Requires -Version 5.1
<#
    AMBIENTEIA - diagnostico em console (SOMENTE LEITURA)
    Usa exatamente a mesma funcao Invoke-AiDiagnostics do botao DIAGNOSTICO da interface.
    Nao inicia, encerra nem altera nada.
#>
$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$core = Join-Path $root 'Core\Ambiente-IA.Core.ps1'
if (-not (Test-Path -LiteralPath $core -PathType Leaf)) {
    Write-Host "[ERRO] Ambiente-IA.Core.ps1 nao encontrado em: $root" -ForegroundColor Red
    exit 1
}

. $core

$logsDir = Join-Path $root 'Logs'
if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$global:AiRoot = $root
$global:AiLogFile = Join-Path $logsDir ("diagnostico-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

Write-Host '======================================================================' -ForegroundColor White
Write-Host '  DIAGNOSTICO DO AMBIENTE IA (somente leitura)' -ForegroundColor White
Write-Host '======================================================================' -ForegroundColor White

$result = @(Invoke-AiDiagnostics)
$summary = $result[$result.Count - 1]

Write-Host ''
Write-Host "Relatorio salvo em: $($global:AiLogFile)" -ForegroundColor DarkGray
if ($summary.Errors -gt 0) { exit 1 }
exit 0