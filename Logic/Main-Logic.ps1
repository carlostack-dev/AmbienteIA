#Requires -Version 5.1
<#
    AMBIENTEIA - janela grafica (PowerShell + WPF)
    Hermes -> Headroom -> NVIDIA NIM

    Este arquivo cuida da JANELA. Toda a logica de servidores esta em Core\Ambiente-IA.Core.ps1.

    Parametro -SmokeTest: monta a janela e valida os controles, sem exibi-la.
#>
[CmdletBinding()]
param([switch]$SmokeTest)

$ErrorActionPreference = 'Stop'

$script:Root      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:CorePath  = Join-Path $script:Root 'Core\Ambiente-IA.Core.ps1'
$script:XamlPath  = Join-Path $script:Root 'Interface\Interface.xaml'
$script:AssetsDir = Join-Path $script:Root 'Assets'
$script:LogsDir   = Join-Path $script:Root 'Logs'
$script:Job       = $null
$script:Poller    = $null
$script:StatsJob  = $null
$script:Mutex     = $null
# Bloqueio atomico para lancamentos de Hermes (INICIAR AMBIENTE e ABRIR HERMES
# compartilham o mesmo mecanismo), evitando duas instancias simultaneas.
$script:HermesLaunchInProgress = $false
$script:LastDot   = @{}
$script:ErrorHistory = @()
$script:ActivityHistory = @()
$script:MaxHistory = 200

function Show-FatalError {
    param([string]$Text)
    try {
        if (-not (Test-Path -LiteralPath $script:LogsDir)) { New-Item -ItemType Directory -Path $script:LogsDir -Force | Out-Null }
        $f = Join-Path $script:LogsDir 'interface-erro.log'
        [System.IO.File]::AppendAllText($f, ("[{0}] {1}`r`n" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show($Text, 'AmbienteIA', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    } catch { }
}

function New-Brush {
    param([string]$Hex)
    $b = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
    $b.Freeze()
    return $b
}

function Set-LogoImage {
    param($ImageControl, [string]$FileName)
    $p = Join-Path $script:AssetsDir $FileName
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = 'OnLoad'
        $bmp.UriSource = New-Object System.Uri($p)
        $bmp.EndInit()
        $bmp.Freeze()
        $ImageControl.Source = $bmp
        return $bmp
    } catch {
        Write-AppLog 'WARN' "Não foi possível carregar a imagem $FileName."
        return $null
    }
}

function Add-Activity {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $entry = "[$ts] [$Level] $Message"
    $script:ActivityHistory += $entry
    if ($script:ActivityHistory.Count -gt $script:MaxHistory) {
        $script:ActivityHistory = $script:ActivityHistory[-$script:MaxHistory..-1]
    }
}

function Add-ErrorLine {
    param([string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $entry = "[$ts] $Message"
    $script:ErrorHistory += $entry
    if ($script:ErrorHistory.Count -gt $script:MaxHistory) {
        $script:ErrorHistory = $script:ErrorHistory[-$script:MaxHistory..-1]
    }
}

function Add-LogLine {
    param([string]$Time, [string]$Level, [string]$Message)
    $brush = $script:Brushes['INFO']
    switch ($Level) {
        'OK'    { $brush = $script:Brushes['OK'] }
        'WARN'  { $brush = $script:Brushes['WARN'] }
        'ERROR' { $brush = $script:Brushes['ERROR'] }
        'DIAG'  { $brush = $script:Brushes['DIAG'] }
    }
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness(0)
    $r1 = New-Object System.Windows.Documents.Run("[$Time] ")
    $r1.Foreground = $script:Brushes['TIME']
    $r2 = New-Object System.Windows.Documents.Run($Message)
    $r2.Foreground = $brush
    $p.Inlines.Add($r1)
    $p.Inlines.Add($r2)
    $doc = $script:ui['LogBox'].Document
    $doc.Blocks.Add($p)
    while ($doc.Blocks.Count -gt 600) { $doc.Blocks.Remove($doc.Blocks.FirstBlock) }

    Add-Activity -Level $Level -Message $Message
    if ($Level -eq 'ERROR') {
        Add-ErrorLine -Message $Message
        Update-HistoryLists
    }
}

function Set-Dot {
    param($Ellipse, [string]$Key, [string]$State)
    if ($script:LastDot[$Key] -eq $State) { return }
    $script:LastDot[$Key] = $State

    $Ellipse.Fill = $script:StateBrush[$State]
    $Ellipse.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $Ellipse.Opacity = 1.0
    if ($State -eq 'STARTING' -or $State -eq 'CHECKING') {
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.3, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(800))))
        $anim.AutoReverse = $true
        $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $Ellipse.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
    }
}

function Update-HistoryLists {
    $ui = $script:ui

    # Erros (últimos 50) - ListBox usa Items, nao Document
    $ui.ErrorList.Items.Clear()
    $start = [math]::Max(0, $script:ErrorHistory.Count - 50)
    for ($i = $start; $i -lt $script:ErrorHistory.Count; $i++) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $script:ErrorHistory[$i]
        $tb.Foreground = $script:Brushes.ERROR
        $tb.Margin = New-Object System.Windows.Thickness(2,0,2,0)
        $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $ui.ErrorList.Items.Add($tb)
    }

    # Historico (últimos 50)
    $ui.HistoryList.Items.Clear()
    $startH = [math]::Max(0, $script:ActivityHistory.Count - 50)
    for ($i = $startH; $i -lt $script:ActivityHistory.Count; $i++) {
        $entry = $script:ActivityHistory[$i]
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $entry
        $tb.Margin = New-Object System.Windows.Thickness(2,0,2,0)
        $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
        if ($entry -like '*[ERROR]*') { $tb.Foreground = $script:Brushes.ERROR }
        elseif ($entry -like '*[OK]*') { $tb.Foreground = $script:Brushes.OK }
        elseif ($entry -like '*[WARN]*') { $tb.Foreground = $script:Brushes.WARN }
        else { $tb.Foreground = $script:Brushes.INFO }
        $ui.HistoryList.Items.Add($tb)
    }
}

function Get-ViewModel {
    $s = $global:AiState
    $vm = @{
        Headroom = 'CHECKING'; Nvidia = 'CHECKING'; Hermes = 'CHECKING'; Overall = 'CHECKING'
        HeadroomDetail = ''; NvidiaDetail = ''; HermesDetail = ''
    }

    if (-not $s['Polled']) { return $vm }

    switch ($s['HeadroomState']) {
        'ONLINE'   { $vm.Headroom = 'ONLINE' }
        'STARTING' { $vm.Headroom = 'STARTING' }
        default    { if ($s['WaitHeadroom']) { $vm.Headroom = 'STARTING' } else { $vm.Headroom = 'OFFLINE' } }
    }

    if ($s['HermesCount'] -gt 0) { $vm.Hermes = 'RUNNING' } else { $vm.Hermes = 'NOT STARTED' }

    $startRunning = ($null -ne $script:Job -and $script:Job.Kind -eq 'start')
    if ($startRunning) { $vm.Overall = 'STARTING' }
    elseif ($vm.Headroom -eq 'ONLINE' -and $vm.Hermes -eq 'RUNNING') { $vm.Overall = 'ONLINE' }
    elseif ($vm.Headroom -eq 'OFFLINE' -and $vm.Hermes -eq 'NOT STARTED') { $vm.Overall = 'OFFLINE' }
    else { $vm.Overall = 'PARTIAL' }

    $live = '/livez sem resposta'
    if ($s['LivezStatus'] -gt 0) { $live = "/livez $($s['LivezStatus'])" }
    $rdy = '/readyz —'
    if ($s['ReadyzStatus'] -gt 0) { $rdy = "/readyz $($s['ReadyzStatus'])" }
    $up = ''
    if ($s['LivezStatus'] -gt 0 -and $s['ReadyzStatus'] -gt 0) { $up = " · upstream $($s['UpstreamStatus'])" }
    $vm.HeadroomDetail = "$live · $rdy$up"

    $ver = ''
    if (-not [string]::IsNullOrWhiteSpace($s['HeadroomVersion'])) { $ver = " v$($s['HeadroomVersion'])" }
    $vm.NvidiaDetail = "NVIDIA_BASE_URL = $($global:AiCfg.NvidiaBaseUrl)$ver · modelo: $($global:AiCfg.HermesExpectedModel)"
    $vm.Nvidia = if ($s['NvidiaReachable'] -eq $true) { 'ONLINE' } elseif ($s['NvidiaTested'] -eq $true) { 'OFFLINE' } else { 'CHECKING' }

    if ($vm.Hermes -eq 'RUNNING') { $vm.HermesDetail = "Processo ativo ($($s['HermesCount']))." }
    else { $vm.HermesDetail = 'Nenhuma sessão aberta.' }

    return $vm
}

function Add-TickDebug {
    param([string]$Stage)
    # Desligado por producao para evitar crescimento ilimitado do tick-debug.log.
    # Ativar temporariamente definindo $script:TickDebugEnabled = $true antes de iniciar o timer.
    if (-not $script:TickDebugEnabled) { return }
    try {
        [System.IO.File]::AppendAllText((Join-Path $script:LogsDir 'tick-debug.log'), ("[{0}] {1}`r`n" -f (Get-Date).ToString('HH:mm:ss.fff'), $Stage), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Update-View {
    $vm = Get-ViewModel
    $ui = $script:ui
    Add-TickDebug 'UV-start'

    $ui.HeadroomStatus.Text = $vm.Headroom
    Add-TickDebug 'UV-headroom-text'
    $ui.NvidiaStatus.Text   = $vm.Nvidia
    Add-TickDebug 'UV-nvidia-text'
    $ui.HermesStatus.Text   = $vm.Hermes
    Add-TickDebug 'UV-hermes-text'
    $ui.OverallText.Text    = $vm.Overall
    Add-TickDebug 'UV-overall-text'

    $ui.HeadroomDetail.Text = $vm.HeadroomDetail
    Add-TickDebug 'UV-headroom-detail'
    $ui.NvidiaDetail.Text   = $vm.NvidiaDetail
    Add-TickDebug 'UV-nvidia-detail'
    $ui.HermesDetail.Text   = $vm.HermesDetail
    Add-TickDebug 'UV-hermes-detail'

    Set-Dot $ui.HeadroomDot 'hr' $vm.Headroom
    Add-TickDebug 'UV-dot-hr'
    Set-Dot $ui.NvidiaDot   'nv' $vm.Nvidia
    Add-TickDebug 'UV-dot-nv'
    Set-Dot $ui.HermesDot   'hm' $vm.Hermes
    Add-TickDebug 'UV-dot-hm'
    Set-Dot $ui.OverallDot  'ov' $vm.Overall
    Add-TickDebug 'UV-dot-ov'

    $idle = ($null -eq $script:Job)
    Add-TickDebug 'UV-idle'
    $ui.StartButton.IsEnabled      = $idle
    Add-TickDebug 'UV-start-enabled'
    $ui.StopButton.IsEnabled       = (-not $idle) -or (@(Get-ManagedProcesses).Count -gt 0)
    Add-TickDebug 'UV-stop-enabled'
    $ui.DiagButton.IsEnabled       = $idle
    Add-TickDebug 'UV-diag-enabled'
    $ui.TestNvidiaButton.IsEnabled = $idle
    Add-TickDebug 'UV-nvidia-test-enabled'
    $ui.TestHeadroomButton.IsEnabled = $idle
    Add-TickDebug 'UV-headroom-test-enabled'
    $ui.StatsButton.IsEnabled      = $idle
    Add-TickDebug 'UV-stats-enabled'
    $ui.OpenHermesButton.IsEnabled = ($idle -and $vm.Headroom -eq 'ONLINE')
    Add-TickDebug 'UV-hermes-enabled'
    $ui.OpenLogsButton.IsEnabled   = $idle
    Add-TickDebug 'UV-logs-enabled'
    $ui.OpenConfigButton.IsEnabled = $idle
    Add-TickDebug 'UV-config-enabled'

    $kind = ''
    if ($null -ne $script:Job) { $kind = $script:Job.Kind }
    Add-TickDebug 'UV-kind'
    if ($kind -eq 'start') {
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Value = [double]$global:AiState['Progress']
    } elseif ($idle) {
        $ui.Progress.IsIndeterminate = $false
        $ui.Progress.Value = [double]$global:AiState['Progress']
    } else {
        $ui.Progress.IsIndeterminate = $true
    }
    Add-TickDebug 'UV-progress'
    $ui.PhaseText.Text = [string]$global:AiState['Phase']
    Add-TickDebug 'UV-phase'

    if ($global:AiState['StatsSummary']) {
        Add-TickDebug 'UV-stats-if'
        $st = $global:AiState['StatsSummary']
        Add-TickDebug 'UV-stats-get'
        $ui.MetricRequests.Text = [string]$st.Requests
        Add-TickDebug 'UV-metric-req'
        $ui.MetricTokens.Text   = [string]$st.TokensSaved
        Add-TickDebug 'UV-metric-tok'
        $ui.MetricLatency.Text  = "$([string]$st.AvgLatencyMs) ms"
        Add-TickDebug 'UV-metric-lat'
        $ui.MetricConnection.Text = if ($st.Provider -eq 'NVIDIA NIM') { 'NVIDIA NIM' } else { '--' }
        Add-TickDebug 'UV-metric-conn'
    }

    Update-HistoryLists
    Add-TickDebug 'UV-history'
    Add-TickDebug 'UV-end'
}

function Complete-Job {
    $j = $script:Job
    if ($null -eq $j) { return }
    try {
        [void]$j.PS.EndInvoke($j.Handle)
    } catch {
        Write-AppLog 'ERROR' "Falha inesperada na operacao: $($_.Exception.Message)"
    }
    try {
        foreach ($er in @($j.PS.Streams.Error)) {
            Write-AppLog 'ERROR' ([string]$er)
        }
    } catch { }
    try { $j.PS.Dispose() } catch { }
    try { $j.RS.Close(); $j.RS.Dispose() } catch { }
    $script:Job = $null
}

function New-BackgroundRunspace {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('AiLogQueue', $global:AiLogQueue)
    $rs.SessionStateProxy.SetVariable('AiState', $global:AiState)
    $rs.SessionStateProxy.SetVariable('AiLogFile', $global:AiLogFile)
    $rs.SessionStateProxy.SetVariable('AiRoot', $script:Root)
    # Estruturas compartilhadas entre runspaces (mesma instancia, nao copia).
    # Essenciais para que o background runspace veja o registro de processos
    # da sessao atual e grave no mesmo registro persistente.
    $rs.SessionStateProxy.SetVariable('AiManagedPids', $global:AiManagedPids)
    $rs.SessionStateProxy.SetVariable('AiManagedProcessMeta', $global:AiManagedProcessMeta)
    $rs.SessionStateProxy.SetVariable('AiProcessTree', $global:AiProcessTree)
    $rs.SessionStateProxy.SetVariable('AiSessionId', $global:AiSessionId)
    return $rs
}

function Start-BackgroundWork {
    param([string]$Kind, [string]$Command)
    if ($null -ne $script:Job) { return }

    if ($Kind -eq 'start') { $global:AiState['Progress'] = 0 }
    $global:AiState['Phase'] = 'Iniciando...'

    $rs = New-BackgroundRunspace
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $scriptText = 'param($CorePath) . $CorePath; ' + $Command + ' | Out-Null'
    [void]$ps.AddScript($scriptText).AddArgument($script:CorePath)
    $handle = $ps.BeginInvoke()
    $script:Job = @{ Kind = $Kind; PS = $ps; RS = $rs; Handle = $handle }
    Update-View
}

function Start-StatsPolling {
    $rs = New-BackgroundRunspace
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $pollScript = @'
param($CorePath)
. $CorePath
$c = $global:AiCfg
while (-not $AiState['StopStatsPolling']) {
    try {
        $stats = Get-AiStatsSummary
        if ($null -ne $stats) {
            $AiState['StatsSummary'] = $stats
        }
    } catch { }
    Start-Sleep -Milliseconds 2500
}
'@
    [void]$ps.AddScript($pollScript).AddArgument($script:CorePath)
    $handle = $ps.BeginInvoke()
    $script:StatsJob = @{ PS = $ps; RS = $rs; Handle = $handle }
}

function Start-StatusPoller {
    $rs = New-BackgroundRunspace
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $pollScript = @'
param($CorePath)
. $CorePath
$c = $global:AiCfg
while (-not $AiState['StopPolling']) {
    try {
        $hh = Get-HeadroomHealth -BaseUrl $c.HeadroomBaseUrl
        $AiState['HeadroomState']   = [string]$hh.State
        $AiState['LivezStatus']     = [int]$hh.LivezStatus
        $AiState['ReadyzStatus']    = [int]$hh.ReadyzStatus
        $AiState['UpstreamStatus']  = [string]$hh.UpstreamStatus
        $AiState['HeadroomVersion'] = [string]$hh.Version
        $AiState['HermesCount']     = [int]@(Get-ManagedHermesProcesses).Count
        $AiState['Polled']          = $true
    } catch { }
    Start-Sleep -Milliseconds 2500
}
'@
    [void]$ps.AddScript($pollScript).AddArgument($script:CorePath)
    $handle = $ps.BeginInvoke()
    $script:Poller = @{ PS = $ps; RS = $rs; Handle = $handle }
}

function Invoke-UiTick {
    try {
        $item = $null
        $n = 0
        while ($n -lt 60 -and $global:AiLogQueue.TryDequeue([ref]$item)) {
            Add-LogLine -Time $item.Time -Level $item.Level -Message $item.Message
            $n++
        }
        if ($n -gt 0) { $script:ui['LogBox'].ScrollToEnd() }

        if ($null -ne $script:Job -and $script:Job.Handle.IsCompleted) {
            Complete-Job
            # Libera o bloqueio atomico de lancamento de Hermes apos o job concluir,
            # independentemente do Kind (start ou hermes), permitindo um novo lancamento.
            $script:HermesLaunchInProgress = $false
            $script:Job = $null
        }

        Update-View
    } catch {
        $errMsg = "[tick] {0} | Line: {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
        try {
            [System.IO.File]::AppendAllText((Join-Path $script:LogsDir 'interface-erro.log'), ("{0}`r`n" -f $errMsg), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
}

function Set-DarkTitleBar {
    param($Window)
    try {
        Add-Type -Namespace AiEnv -Name Dwm -ErrorAction Stop -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);'
    } catch { }
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        $dark = 1
        [void][AiEnv.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4)
        $caption = 0x140B0B
        [void][AiEnv.Dwm]::DwmSetWindowAttribute($hwnd, 35, [ref]$caption, 4)
        $border = 0xED3A7C
        [void][AiEnv.Dwm]::DwmSetWindowAttribute($hwnd, 34, [ref]$border, 4)
    } catch { }
}

# ------------------------------------------------------------------------------
# PRINCIPAL
# ------------------------------------------------------------------------------
$exitCode = 0
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

    foreach ($req in @($script:CorePath, $script:XamlPath)) {
        if (-not (Test-Path -LiteralPath $req -PathType Leaf)) {
            throw "Arquivo obrigatório não encontrado: $req"
        }
    }

    $mutexName = 'Local\AmbienteIA_GUI'
    if ($SmokeTest) { $mutexName = 'Local\AmbienteIA_GUI_SmokeTest' }
    $createdNew = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        [void][System.Windows.MessageBox]::Show('A interface do AmbienteIA já está aberta.', 'AmbienteIA', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        [Environment]::Exit(0)
    }

    if (-not (Test-Path -LiteralPath $script:LogsDir)) { New-Item -ItemType Directory -Path $script:LogsDir -Force | Out-Null }
    Get-ChildItem -LiteralPath $script:LogsDir -Filter 'ambienteia-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    . $script:CorePath
    $global:AiRoot     = $script:Root
    $global:AiLogFile  = Join-Path $script:LogsDir ("ambienteia-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    $global:AiLogQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $global:AiState    = [hashtable]::Synchronized(@{
        Polled = $false; StopPolling = $false; StopStatsPolling = $false; Progress = 0; Phase = 'Pronto.'
        HeadroomState = 'OFFLINE'; LivezStatus = 0; ReadyzStatus = 0; UpstreamStatus = 'unknown'
        HermesCount = 0; WaitHeadroom = $false; NvidiaReachable = $false; NvidiaTested = $false
        HeadroomVersion = ''
    })

    $script:Brushes = @{
        INFO = New-Brush '#E5E7EB'; OK = New-Brush '#22C55E'; WARN = New-Brush '#FBBF24'
        ERROR = New-Brush '#F87171'; DIAG = New-Brush '#94A3B8'; TIME = New-Brush '#7C6FB0'
    }
    $script:StateBrush = @{
        'ONLINE' = New-Brush '#22C55E'; 'RUNNING' = New-Brush '#22C55E'
        'STARTING' = New-Brush '#F59E0B'; 'PARTIAL' = New-Brush '#F59E0B'; 'CHECKING' = New-Brush '#A78BFA'
        'OFFLINE' = New-Brush '#EF4444'; 'NOT STARTED' = New-Brush '#64748B'
    }

    $xamlText = [System.IO.File]::ReadAllText($script:XamlPath, [System.Text.Encoding]::UTF8)
    $window = [Windows.Markup.XamlReader]::Parse($xamlText)

    $controlNames = @(
        'HeaderLogo', 'OverallBadge', 'OverallDot', 'OverallText', 'Progress', 'PhaseText',
        'HeadroomLogo', 'HeadroomDot', 'HeadroomStatus', 'HeadroomDetail',
        'NvidiaLogo', 'NvidiaDot', 'NvidiaStatus', 'NvidiaDetail',
        'HermesLogo', 'HermesDot', 'HermesStatus', 'HermesDetail', 'ModelText', 'NvidiaModelIcon',
        'StartButton', 'StopButton', 'OpenHermesButton', 'OpenFolderButton', 'DiagButton',
        'TestNvidiaButton', 'TestHeadroomButton', 'StatsButton', 'OpenLogsButton', 'OpenConfigButton',
        'ExitButton', 'LogBox', 'ErrorList', 'HistoryList',
        'MetricRequests', 'MetricTokens', 'MetricLatency', 'MetricConnection'
    )
    $script:ui = @{}
    foreach ($n in $controlNames) {
        $ctl = $window.FindName($n)
        if ($null -eq $ctl) { throw "Controle '$n' não encontrado em Interface.xaml." }
        $script:ui[$n] = $ctl
    }
    $script:Window = $window

    if ($SmokeTest) {
        Write-Host 'SMOKE-TEST OK: XAML carregado e todos os controles encontrados.'
        $script:Mutex.ReleaseMutex()
        [Environment]::Exit(0)
    }

    $hermesBmp = Set-LogoImage $script:ui.HeaderLogo 'hermes.png'
    [void](Set-LogoImage $script:ui.HermesLogo 'hermes.png')
    [void](Set-LogoImage $script:ui.HeadroomLogo 'headroom.png')
    [void](Set-LogoImage $script:ui.NvidiaLogo 'nvidia.png')
    [void](Set-LogoImage $script:ui.NvidiaModelIcon 'nvidia.png')
    if ($null -ne $hermesBmp) { $window.Icon = $hermesBmp }

    $script:ui.LogBox.Document.Blocks.Clear()

    $script:ui.StartButton.Add_Click({
        # Protecao atomica compartilhada com ABRIR HERMES.
        if ($script:HermesLaunchInProgress) {
            Write-AppLog 'WARN' 'Um Hermes ja esta sendo iniciado. Aguarde e tente novamente.'
            return
        }
        $script:HermesLaunchInProgress = $true
        $jobAntes = $script:Job
        try {
            Start-BackgroundWork -Kind 'start' -Command 'Start-AiEnvironment'
            # Se Start-BackgroundWork rejeitou (ja havia um job em andamento),
            # nao houve job novo: libera o bloqueio imediatamente.
            if ($jobAntes -eq $script:Job) {
                $script:HermesLaunchInProgress = $false
            }
        } catch {
            Write-AppLog 'ERROR' "Falha ao iniciar o ambiente: $($_.Exception.Message)"
            $script:HermesLaunchInProgress = $false
        }
        # Nota: se o job foi criado com sucesso, o bloqueio e liberado por
        # Invoke-UiTick quando o job completar (qualquer Kind).
    })
    $script:ui.StopButton.Add_Click({
        if ($null -ne $script:Job) {
            $ans = [System.Windows.MessageBox]::Show('Há uma operação em andamento. Parar agora?', 'AmbienteIA', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }
        Write-AppLog 'INFO' 'Parando ambiente...'
        $stopped = Stop-AiEnvironment
        Add-Activity -Level 'INFO' -Message "$stopped processo(s) gerenciado(s) encerrado(s)."
        Update-View
    })
    $script:ui.OpenHermesButton.Add_Click({
        # Protecao atomica: nao permite lancamento duplo de Hermes.
        if ($script:HermesLaunchInProgress) {
            Write-AppLog 'WARN' 'Um Hermes ja esta sendo iniciado. Aguarde e tente novamente.'
            return
        }
        if ($global:AiState['HermesCount'] -gt 0) {
            $ans = [System.Windows.MessageBox]::Show('Já existe um Hermes em execução. Abrir outra janela?', 'AmbienteIA', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }
        $script:HermesLaunchInProgress = $true
        $jobAntes = $script:Job
        try {
            Start-BackgroundWork -Kind 'hermes' -Command 'Open-HermesOnly'
            # Se Start-BackgroundWork rejeitou (ja havia um job em andamento),
            # nao houve job novo: libera o bloqueio imediatamente.
            if ($jobAntes -eq $script:Job) {
                $script:HermesLaunchInProgress = $false
            }
        } catch {
            Write-AppLog 'ERROR' "Falha ao abrir o Hermes: $($_.Exception.Message)"
            $script:HermesLaunchInProgress = $false
        }
        # Nota: se o job foi criado com sucesso, o bloqueio e liberado por
        # Invoke-UiTick quando o job completar (qualquer Kind), veja linha ~411.
    })
    $script:ui.OpenFolderButton.Add_Click({
        $dir = $global:AiCfg.HermesWorkDir
        if (Test-Path -LiteralPath $dir -PathType Container) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$dir`"" | Out-Null
            Write-AppLog 'INFO' "Pasta aberta: $dir"
            Add-Activity -Level 'INFO' -Message "Pasta aberta: $dir"
        } else {
            Write-AppLog 'ERROR' "A pasta de projetos não existe: $dir"
        }
    })
    $script:ui.DiagButton.Add_Click({
        Start-BackgroundWork -Kind 'diag' -Command 'Invoke-AiDiagnostics'
    })
    $script:ui.TestNvidiaButton.Add_Click({
        Start-BackgroundWork -Kind 'nvidia' -Command 'Test-NvidiaConnection | Out-Null'
    })
    $script:ui.TestHeadroomButton.Add_Click({
        Start-BackgroundWork -Kind 'headroom' -Command 'Test-Headroom | Out-Null'
    })
    $script:ui.StatsButton.Add_Click({
        Start-BackgroundWork -Kind 'stats' -Command 'Get-AiStatsSummary | Out-Null'
    })
    $script:ui.OpenLogsButton.Add_Click({
        $dir = $script:LogsDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$dir`"" | Out-Null
        Write-AppLog 'INFO' "Logs abertos: $dir"
    })
    $script:ui.OpenConfigButton.Add_Click({
        $cfg = $global:AiCfg.HermesConfigPath
        if (Test-Path -LiteralPath $cfg -PathType Leaf) {
            Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$cfg`"" | Out-Null
            Write-AppLog 'INFO' "Config aberto: $cfg"
        } else {
            Write-AppLog 'ERROR' "Config não encontrado: $cfg"
        }
    })
    $script:ui.ExitButton.Add_Click({
        # Antes de fechar a interface, encerra os serviços iniciados pelo AmbienteIA
        # (Headroom e Hermes) para não deixar processos órfãos.
        $running = @(Get-ManagedProcesses)
        $orphanTitles = @('HEADROOM - PROXY', 'HERMES - PROJETOS')
        $orphanProcs = Find-ProcessesByWindowTitle -TitleTerms $orphanTitles
        $hasServices = ($running.Count -gt 0) -or ($orphanProcs.Count -gt 0)

        if ($hasServices) {
            $ans = [System.Windows.MessageBox]::Show(
                "Isso encerrará a interface e também parará os serviços do AmbienteIA (Headroom e Hermes). Deseja continuar?",
                'AmbienteIA',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question)
            if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
        }

        Write-AppLog 'INFO' 'Encerrando ambiente antes de fechar a interface...'
        $stopped = Stop-AiEnvironment
        Add-Activity -Level 'INFO' -Message "$stopped processo(s) encerrado(s) antes de fechar a interface."
        $script:Window.Close()
    })

    $window.Add_SourceInitialized({ Set-DarkTitleBar $script:Window })

    $window.Add_Closing({
        param($sender, $e)
        # Se houver operação em andamento, pergunta ao usuário
        if ($null -ne $script:Job) {
            $ans = [System.Windows.MessageBox]::Show("Há uma operação em andamento. Fechar a interface agora?`n`nOs serviços já iniciados continuam rodando.", 'AmbienteIA', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true }
        }

        # Se não foi cancelado, encerra os serviços do AmbienteIA (Headroom/Hermes)
        # antes de permitir o fechamento da janela.
        if (-not $e.Cancel) {
            $running = @(Get-ManagedProcesses)
            $orphanTitles = @('HEADROOM - PROXY', 'HERMES - PROJETOS')
            $orphanProcs = Find-ProcessesByWindowTitle -TitleTerms $orphanTitles
            $hasServices = ($running.Count -gt 0) -or ($orphanProcs.Count -gt 0)

            if ($hasServices) {
                $ans = [System.Windows.MessageBox]::Show(
                    "Isso encerrará os serviços do AmbienteIA (Headroom e Hermes) antes de fechar a interface. Deseja continuar?",
                    'AmbienteIA',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question)
                if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true }
                else {
                    Write-AppLog 'INFO' 'Encerrando ambiente antes de fechar a janela...'
                    $stopped = Stop-AiEnvironment
                    Add-Activity -Level 'INFO' -Message "$stopped processo(s) encerrado(s) antes de fechar a janela."
                }
            }
        }
    })

    $window.Add_Closed({
        $global:AiState['StopPolling'] = $true
        $global:AiState['StopStatsPolling'] = $true
        try { $script:Timer.Stop() } catch { }
        try { if ($null -ne $script:Job) { [void]$script:Job.PS.BeginStop($null, $null) } } catch { }
        try { if ($null -ne $script:Poller) { [void]$script:Poller.Handle.AsyncWaitHandle.WaitOne(3000) } } catch { }
        try { if ($null -ne $script:StatsJob) { [void]$script:StatsJob.Handle.AsyncWaitHandle.WaitOne(3000) } } catch { }
        try { $script:Mutex.ReleaseMutex() } catch { }
    })

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:Timer.Add_Tick({ Invoke-UiTick })

    Write-AppLog 'INFO' 'Interface iniciada. Verificando serviços...'
    if (Test-AdminContext) {
        Write-AppLog 'WARN' 'O aplicativo está rodando como administrador. Isso não é necessário nem recomendado.'
    }
    Update-View
    Start-StatusPoller
    Start-StatsPolling
    $script:Timer.Start()

    [void]$window.ShowDialog()
} catch {
    $exitCode = 1
    Show-FatalError ("Falha ao abrir a interface:`n`n" + $_.Exception.Message)
}

[Environment]::Exit($exitCode)