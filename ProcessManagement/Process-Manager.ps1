#Requires -Version 5.1
<#
    Gerenciamento de processos iniciados pelo AmbienteIA.
    Funcoes para listar, encerrar e evitar processos duplicados.
#>
param([switch]$List, [switch]$Stop)

$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$core = Join-Path $root 'Core\Ambiente-IA.Core.ps1'
if (-not (Test-Path -LiteralPath $core -PathType Leaf)) {
    Write-Host "[ERRO] Ambiente-IA.Core.ps1 nao encontrado em: $root" -ForegroundColor Red
    exit 1
}

. $core

if ($List) {
    $procs = Get-ManagedProcesses
    if ($procs.Count -eq 0) {
        Write-Host "Nenhum processo gerenciado pelo AmbienteIA em execucao." -ForegroundColor Gray
    } else {
        Write-Host "Processos gerenciados pelo AmbienteIA:" -ForegroundColor Cyan
        foreach ($p in $procs) {
            Write-Host "  PID $($p.Id) - $($p.ProcessName) - Iniciado em: $($p.StartTime)" -ForegroundColor White
        }
    }
    exit 0
}

if ($Stop) {
    $count = Stop-AiEnvironment
    Write-Host "$count processo(s) gerenciado(s) encerrado(s)." -ForegroundColor Green
    exit 0
}

Write-Host "Uso: Process-Manager.ps1 [-List] [-Stop]" -ForegroundColor Gray