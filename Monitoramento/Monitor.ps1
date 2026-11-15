#Requires -Version 5.1
<#
    Monitoramento de estatisticas do Headroom (somente leitura).
    Pode ser executado de forma independente ou integrado na interface.
#>
param([int]$IntervalMs = 2500)

$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$core = Join-Path $root 'Core\Ambiente-IA.Core.ps1'
if (-not (Test-Path -LiteralPath $core -PathType Leaf)) {
    Write-Host "[ERRO] Ambiente-IA.Core.ps1 nao encontrado em: $root" -ForegroundColor Red
    exit 1
}

. $core

$c = $global:AiCfg
Write-Host "Monitorando estatisticas do Headroom em $($c.HeadroomBaseUrl)/stats (Ctrl+C para parar)..." -ForegroundColor Cyan
Write-Host ''

try {
    while ($true) {
        $ts = (Get-Date).ToString('HH:mm:ss')
        $h = Get-HeadroomHealth -BaseUrl $c.HeadroomBaseUrl
        $stats = Get-AiStatsSummary

        if ($h.Ready) {
            Write-Host "[$ts] Headroom ONLINE (/livez=$($h.LivezStatus) /readyz=$($h.ReadyzStatus) upstream=$($h.UpstreamStatus))" -ForegroundColor Green
        } else {
            Write-Host "[$ts] Headroom $($h.State) - $($h.Detail)" -ForegroundColor Yellow
        }

        if ($null -ne $stats) {
            Write-Host "  Requisicoes: $($stats.Requests)  Tokens salvos: $($stats.TokensSaved)  Latencia media: $($stats.AvgLatencyMs) ms  Provedor: $($stats.Provider)" -ForegroundColor Cyan
        } else {
            Write-Host "  Estatisticas indisponiveis." -ForegroundColor Gray
        }

        Start-Sleep -Milliseconds $IntervalMs
    }
} catch {
    Write-Host '' -ForegroundColor Cyan
    Write-Host 'Monitoramento encerrado.' -ForegroundColor Cyan
}