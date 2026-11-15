#Requires -Version 5.1
# ==============================================================================
# Ambiente-IA.Core.ps1
# Biblioteca COMPARTILHADA do projeto AmbienteIA (somente funcoes).
#
# Toda a logica de deteccao, inicializacao, diagnostico e monitoramento vive
# aqui. A interface grafica (Iniciar-AmbienteIA.ps1) e o diagnostico em console
# (Diagnostico.ps1) apenas chamam estas funcoes.
#
# Nada e executado ao carregar este arquivo (dot-source).
#
# Saida de log: Write-AppLog
#   - com $global:AiLogQueue definido (GUI) -> enfileira para a interface
#   - sem fila (console)                    -> Write-Host colorido
# ==============================================================================

# ------------------------------------------------------------------------------
# PARAMETROS DO AMBIENTE (EDITE APENAS SE NECESSARIO)
# ------------------------------------------------------------------------------
$global:AiCfg = @{
    # Headroom (proxy de contexto)
    HeadroomHost           = '127.0.0.1'
    HeadroomPort           = 8787
    HeadroomBaseUrl        = 'http://127.0.0.1:8787'
    HeadroomPythonManual   = ''     # Opcional: caminho manual para o python.exe com Headroom
    HeadroomSubcommand     = '-m headroom.cli proxy'
    HeadroomTimeoutSec     = 45
    HeadroomExpectedVersion = '0.44.0'

    # Hermes
    HermesExePrimary       = "$env:LOCALAPPDATA\AmbienteIA\hermes\bin\hermes.exe"
    HermesWorkDir          = 'C:\Projetos'
    HermesConfigPath       = "$env:LOCALAPPDATA\AmbienteIA\hermes\config.yaml"
    HermesEnvPath          = "$env:LOCALAPPDATA\AmbienteIA\hermes\.env"
    HermesExpectedModel    = 'nvidia/nemotron-3.5-super-vl-120b-a12b'

    # NVIDIA NIM
    NvidiaBaseUrl          = 'http://127.0.0.1:8787/v1'
    NvidiaNimEndpoint      = 'https://integrate.api.nvidia.com/v1'
    NvidiaDefaultModel     = 'nvidia/nemotron-3.5-super-vl-120b-a12b'

    # Processos gerenciados pelo AmbienteIA (para parada seletiva)
    ManagedProcessTag      = 'AmbienteIA'
}

# ------------------------------------------------------------------------------
# LOG (com mascaramento de segredos)
# ------------------------------------------------------------------------------
function Protect-LogText {
    # Ultima linha de defesa: nenhuma mensagem de log sai daqui com segredos.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, '(?i)\b(bearer)\s+[A-Za-z0-9\-\._~\/+=]{8,}', '$1 ***')
    $t = [regex]::Replace($t, '(?i)\b(api[_-]?key|apikey|x-api-key|token|secret|password|passwd|authorization)\b(\s*[:=]\s*)("[^"]*"|''[^'']*''|\S+)', '$1$2***')
    $t = [regex]::Replace($t, '\b(sk|pk|rk|ghp|gho|xox[abp])[-_][A-Za-z0-9_\-]{10,}', '***')
    $t = [regex]::Replace($t, '\b[A-Za-z0-9_\-]{40,}\b', '***')
    return $t
}

function Write-AppLog {
    param(
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DIAG')][string]$Level = 'INFO',
        [string]$Message
    )
    $msg = Protect-LogText $Message
    $ts = (Get-Date).ToString('HH:mm:ss')

    if ($null -ne $global:AiLogQueue) {
        $global:AiLogQueue.Enqueue([pscustomobject]@{ Time = $ts; Level = $Level; Message = $msg })
    } else {
        $color = 'Gray'
        switch ($Level) {
            'OK'    { $color = 'Green' }
            'WARN'  { $color = 'Yellow' }
            'ERROR' { $color = 'Red' }
            'DIAG'  { $color = 'DarkGray' }
            'INFO'  { $color = 'Cyan' }
        }
        Write-Host "[$ts] $msg" -ForegroundColor $color
    }

    if (-not [string]::IsNullOrWhiteSpace($global:AiLogFile)) {
        try {
            $line = "[$ts] [$Level] $msg`r`n"
            [System.IO.File]::AppendAllText($global:AiLogFile, $line, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
}

function Set-AiState {
    param([string]$Key, $Value)
    if ($null -ne $global:AiState) { $global:AiState[$Key] = $Value }
}

function Test-True {
    param($Value)
    $a = @($Value)
    return ($a.Count -gt 0 -and $a[$a.Count - 1] -eq $true)
}

function Test-AdminContext {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ------------------------------------------------------------------------------
# REDE E HEALTHCHECKS
# ------------------------------------------------------------------------------
function Test-TcpPortOpen {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs = 800
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        $connected = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $connected) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Invoke-HttpProbe {
    param(
        [string]$Url,
        [int]$TimeoutMs = 2000
    )
    $r = [pscustomobject]@{ Status = 0; Body = ''; Error = '' }
    $resp = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.Proxy = $null
        $req.KeepAlive = $false
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) {
            $r.Error = $_.Exception.Message
            return $r
        }
    } catch {
        $r.Error = $_.Exception.Message
        return $r
    }

    try {
        $r.Status = [int]$resp.StatusCode
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $body = $sr.ReadToEnd()
        $sr.Dispose()
        if ($body.Length -gt 65536) { $body = $body.Substring(0, 65536) }
        $r.Body = $body
    } catch { }
    finally {
        $resp.Close()
    }
    return $r
}

function Get-HeadroomHealth {
    # Estado: OFFLINE (sem resposta) | STARTING (responde, mas nao pronto) | ONLINE.
    param([string]$BaseUrl = $global:AiCfg.HeadroomBaseUrl)

    $result = [pscustomobject]@{
        LivezStatus     = 0
        ReadyzStatus    = 0
        UpstreamStatus  = 'unknown'
        UpstreamHealthy = $false
        Ready           = $false
        State           = 'OFFLINE'
        Detail          = ''
        Version         = ''
    }

    $live = Invoke-HttpProbe -Url "${BaseUrl}/livez" -TimeoutMs 2000
    $result.LivezStatus = $live.Status
    if ($live.Status -ne 200) {
        if ($live.Status -eq 0) {
            $result.Detail = "Falha em /livez: $($live.Error)"
        } else {
            $result.State = 'STARTING'
            $result.Detail = "/livez retornou HTTP $($live.Status)"
        }
        return $result
    }

    # Extrair versao do corpo do /livez se disponível
    try {
        $liveJson = $live.Body | ConvertFrom-Json
        if ($null -ne $liveJson -and $liveJson.PSObject.Properties.Name -contains 'version') {
            $result.Version = [string]$liveJson.version
        }
    } catch { }

    $result.State = 'STARTING'

    $ready = Invoke-HttpProbe -Url "${BaseUrl}/readyz" -TimeoutMs 2000
    $result.ReadyzStatus = $ready.Status
    if ($ready.Status -ne 200) {
        if ($ready.Status -eq 0) {
            $result.Detail = "Falha em /readyz: $($ready.Error)"
        } else {
            $result.Detail = "/readyz retornou HTTP $($ready.Status)"
        }
        return $result
    }

    $readyzJson = $null
    try { $readyzJson = $ready.Body | ConvertFrom-Json } catch { $result.Detail = 'Resposta de /readyz nao e um JSON valido'; return $result }
    if ($null -eq $readyzJson) { $result.Detail = 'JSON vazio em /readyz'; return $result }

    $topProps = @($readyzJson.PSObject.Properties | ForEach-Object { $_.Name })

    # Procura upstream no nivel raiz e sob 'checks' (formato atual do Headroom 0.44.x)
    $upNode = $null
    if ($topProps -contains 'upstream' -and $null -ne $readyzJson.upstream) {
        $upNode = $readyzJson.upstream
    } elseif ($topProps -contains 'checks' -and $null -ne $readyzJson.checks) {
        $checks = $readyzJson.checks
        if ($null -ne $checks.upstream) { $upNode = $checks.upstream }
    }

    if ($null -ne $upNode) {
        if ($upNode -is [pscustomobject]) {
            $upProps = @($upNode.PSObject.Properties | ForEach-Object { $_.Name })
            if ($upProps -contains 'status' -and $null -ne $upNode.status) {
                $result.UpstreamStatus = [string]$upNode.status
            }
        } elseif ($upNode -is [string]) {
            $result.UpstreamStatus = $upNode
        }
    }

    if ($result.UpstreamStatus.Trim().ToLowerInvariant() -eq 'healthy') {
        $result.UpstreamHealthy = $true
        $result.Ready = $true
        $result.State = 'ONLINE'
    } else {
        $result.Detail = "upstream.status atual: '$($result.UpstreamStatus)' (esperado: 'healthy')"
    }
    return $result
}

function Get-HeadroomStats {
    # Busca estatisticas reais de /stats. Retorna null se falhar.
    param([string]$BaseUrl = $global:AiCfg.HeadroomBaseUrl)
    $probe = Invoke-HttpProbe -Url "${BaseUrl}/stats" -TimeoutMs 3000
    if ($probe.Status -ne 200) { return $null }
    try {
        return $probe.Body | ConvertFrom-Json
    } catch {
        return $null
    }
}

# ------------------------------------------------------------------------------
# DESCOBERTA DO PYTHON COM HEADROOM
# ------------------------------------------------------------------------------
function Test-IsWindowsAppsStub {
    param([string]$ExePath)
    if ([string]::IsNullOrWhiteSpace($ExePath)) { return $true }
    $normalized = $ExePath.Trim().Trim('"').Replace('/', '\')
    if ($normalized -like '*\Microsoft\WindowsApps\python*.exe') { return $true }
    return $false
}

function Test-PythonHasHeadroom {
    param([string]$PythonExe)
    if ([string]::IsNullOrWhiteSpace($PythonExe)) { return $null }
    if (Test-IsWindowsAppsStub -ExePath $PythonExe) { return $null }
    if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) { return $null }

    $ErrorActionPreference = 'Continue'
    try {
        $probeCode = "import headroom, headroom.cli; print(getattr(headroom, '__version__', 'installed'))"
        $versionOut = & $PythonExe -c $probeCode 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $versionStr = (@($versionOut) -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($versionStr)) { return $null }

        $proxyHelpOut = & $PythonExe -m headroom.cli proxy --help 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }

        return $versionStr
    } catch {
        return $null
    }
}

function Resolve-HeadroomPython {
    param(
        [string]$ManualPython,
        [string]$WorkDir
    )
    $ErrorActionPreference = 'Continue'

    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    $addCandidate = {
        param([string]$PathToAdd)
        if ([string]::IsNullOrWhiteSpace($PathToAdd)) { return }
        $clean = $PathToAdd.Trim().Trim('"').Replace('/', '\\')
        if (Test-IsWindowsAppsStub -ExePath $clean) {
            Write-AppLog 'DIAG' "Ignorando stub da Microsoft Store: $clean"
            return
        }
        if ((Test-Path -LiteralPath $clean -PathType Leaf) -and $seen.Add($clean)) {
            $candidates.Add($clean)
        }
    }

    # 1. Override manual
    if (-not [string]::IsNullOrWhiteSpace($ManualPython)) { & $addCandidate $ManualPython }

    # 2. Caminho real do usuario: %LOCALAPPDATA%\Python\pythoncore-3.14-64\python.exe
    $pyCore = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Python\pythoncore-3.14-64\python.exe'
    & $addCandidate $pyCore

    # 3. Ambientes virtuais locais
    foreach ($baseFolder in @($WorkDir, $env:USERPROFILE, (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'headroom'))) {
        if (-not [string]::IsNullOrWhiteSpace($baseFolder) -and (Test-Path -LiteralPath $baseFolder -PathType Container)) {
            foreach ($venvName in @('.venv', 'venv', 'env', 'headroom-env', '.headroom')) {
                & $addCandidate (Join-Path -Path $baseFolder -ChildPath "$venvName\Scripts\python.exe")
            }
        }
    }

    # 4. Ambientes isolados de pipx e uv
    $toolRoots = @(
        (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'pipx\venvs'),
        (Join-Path -Path $env:USERPROFILE -ChildPath '.local\pipx\venvs'),
        (Join-Path -Path $env:APPDATA -ChildPath 'uv\tools'),
        (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'uv\tools'),
        (Join-Path -Path $env:USERPROFILE -ChildPath '.local\share\uv\tools')
    )
    foreach ($tr in $toolRoots) {
        if (Test-Path -LiteralPath $tr -PathType Container) {
            $dirs = @(Get-ChildItem -Path $tr -Directory -Filter '*headroom*' -ErrorAction SilentlyContinue)
            foreach ($d in $dirs) { & $addCandidate (Join-Path -Path $d.FullName -ChildPath 'Scripts\python.exe') }
        }
    }

    # 5. where.exe python
    try {
        $whereOut = & where.exe python 2>$null
        if ($LASTEXITCODE -eq 0 -and $null -ne $whereOut) {
            foreach ($w in @($whereOut)) { & $addCandidate $w }
        }
    } catch { }

    # 6. Python Launcher (py -0p)
    $pyLauncher = Get-Command -Name 'py' -ErrorAction SilentlyContinue
    if ($null -ne $pyLauncher) {
        try {
            $pyList = & py -0p 2>$null
            if ($LASTEXITCODE -eq 0 -and $null -ne $pyList) {
                foreach ($entry in @($pyList)) {
                    $lineText = [string]$entry
                    $driveIdx = $lineText.IndexOf(':\')
                    if ($driveIdx -ge 1) {
                        $extracted = $lineText.Substring($driveIdx - 1).Trim()
                        if ($extracted.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                            & $addCandidate $extracted
                        }
                    }
                }
            }
        } catch { }
    }

    # 7. Instalacoes padrao
    $globPatterns = @(
        (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Python\Python*\python.exe'),
        'C:\Python*\python.exe',
        'C:\Program Files\Python*\python.exe',
        (Join-Path -Path $env:USERPROFILE -ChildPath 'miniconda3\python.exe'),
        (Join-Path -Path $env:USERPROFILE -ChildPath 'miniconda3\envs\*\python.exe'),
        (Join-Path -Path $env:USERPROFILE -ChildPath 'anaconda3\python.exe'),
        (Join-Path -Path $env:USERPROFILE -ChildPath 'anaconda3\envs\*\python.exe'),
        (Join-Path -Path $env:USERPROFILE -ChildPath 'scoop\apps\python\current\python.exe'),
        (Join-Path -Path $env:USERPROFILE -ChildPath '.pyenv\pyenv-win\versions\*\python.exe')
    )
    foreach ($pattern in $globPatterns) {
        $found = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
        foreach ($f in $found) { & $addCandidate $f.FullName }
    }

    Write-AppLog 'DIAG' "Interpretadores Python candidatos (sem WindowsApps): $($candidates.Count)"

    foreach ($cand in $candidates) {
        Write-AppLog 'DIAG' "Validando 'headroom.cli proxy' em: $cand"
        $version = Test-PythonHasHeadroom -PythonExe $cand
        if (-not [string]::IsNullOrWhiteSpace($version)) {
            return [pscustomobject]@{ PythonExe = $cand; Version = $version }
        }
    }

    return $null
}

# ------------------------------------------------------------------------------
# DETECCAO DE PROCESSOS (evita instancias duplicadas)
# ------------------------------------------------------------------------------
function Get-HermesProcess {
    return @(Get-Process -Name 'hermes' -ErrorAction SilentlyContinue)
}

function Get-HeadroomProcess {
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'python%'" -ErrorAction Stop |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -like '*headroom.cli*' -and
                $_.CommandLine -like '*proxy*'
            })
        return $procs
    } catch {
        return @()
    }
}

# Processos iniciados pelo AmbienteIA (rastreados por PID)
$script:AiManagedPids = @()

function Register-ManagedProcess {
    param([int]$Pid)
    if ($Pid -gt 0) { $script:AiManagedPids += $Pid }
}

function Get-ManagedProcesses {
    $alive = @()
    foreach ($pid in $script:AiManagedPids) {
        try {
            $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($null -ne $p) { $alive += $p }
        } catch { }
    }
    return $alive
}

# ------------------------------------------------------------------------------
# LANCAMENTO DE JANELAS DE TERMINAL
# ------------------------------------------------------------------------------
function Start-ManagedTerminalWindow {
    param(
        [string]$WindowTitle,
        [string]$WorkingDirectory,
        [string]$CommandLine,
        [ValidateSet('Normal', 'Minimized', 'Hidden')][string]$WindowStyle = 'Normal'
    )
    $cmdArgs = "/k title $WindowTitle && $CommandLine"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -WorkingDirectory $WorkingDirectory -WindowStyle $WindowStyle -PassThru
    Register-ManagedProcess -Pid $proc.Id
    return $proc
}

# ------------------------------------------------------------------------------
# ETAPA 1: HEADROOM
# ------------------------------------------------------------------------------
function Start-HeadroomStep {
    $c = $global:AiCfg

    $health = Get-HeadroomHealth -BaseUrl $c.HeadroomBaseUrl
    if ($health.Ready) {
        Write-AppLog 'OK' "Headroom ja estava ativo (/livez=$($health.LivezStatus), /readyz=$($health.ReadyzStatus), upstream=$($health.UpstreamStatus), v$($health.Version)). Nenhuma nova instancia sera aberta."
        return $true
    }

    $procs = @(Get-HeadroomProcess)
    if (Test-TcpPortOpen -TargetHost $c.HeadroomHost -Port $c.HeadroomPort -TimeoutMs 600) {
        Write-AppLog 'WARN' "A porta $($c.HeadroomPort) ja está aberta. Aguardando estabilizacao ($($health.Detail))..."
    } elseif ($procs.Count -gt 0) {
        Write-AppLog 'WARN' 'Um processo do Headroom ja esta iniciando. Aguardando, sem abrir outra instancia...'
    } else {
        Write-AppLog 'DIAG' 'Buscando interpretador Python com Headroom instalado (ignorando WindowsApps)...'
        $resolvedPy = Resolve-HeadroomPython -ManualPython $c.HeadroomPythonManual -WorkDir $c.HermesWorkDir
        if ($null -eq $resolvedPy) {
            Write-AppLog 'ERROR' "Nenhum interpretador Python com 'headroom.cli proxy' funcional foi encontrado. Verifique a instalacao do Headroom ou informe o python.exe em HeadroomPythonManual."
            return $false
        }
        $pyExe = $resolvedPy.PythonExe
        Write-AppLog 'OK' "Python com Headroom $($resolvedPy.Version): $pyExe"

        $wd = $env:USERPROFILE
        if (Test-Path -LiteralPath $c.HermesWorkDir -PathType Container) { $wd = $c.HermesWorkDir }
        $launchCmd = "echo Iniciando Headroom Proxy (upstream: $($c.NvidiaBaseUrl))... && `"$pyExe`" $($c.HeadroomSubcommand)"
        try {
            Start-ManagedTerminalWindow -WindowTitle 'HEADROOM - PROXY' -WorkingDirectory $wd -CommandLine $launchCmd -WindowStyle Minimized
        } catch {
            Write-AppLog 'ERROR' "Falha ao iniciar o Headroom: $($_.Exception.Message)"
            return $false
        }
        Write-AppLog 'INFO' "Headroom iniciado em janela minimizada 'HEADROOM - PROXY'. Aguardando ficar saudavel..."
    }

    Set-AiState 'WaitHeadroom' $true
    $ready = $false
    $lastDetail = ''
    $deadline = (Get-Date).AddSeconds($c.HeadroomTimeoutSec)
    $nextNote = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        $h = Get-HeadroomHealth -BaseUrl $c.HeadroomBaseUrl
        if ($h.Ready) {
            $ready = $true
            break
        }
        $lastDetail = $h.Detail
        if ((Get-Date) -ge $nextNote) {
            $left = [int]($deadline - (Get-Date)).TotalSeconds
            Write-AppLog 'DIAG' "Aguardando Headroom... (${left}s restantes) $lastDetail"
            $nextNote = (Get-Date).AddSeconds(5)
        }
        Start-Sleep -Milliseconds 750
    }
    Set-AiState 'WaitHeadroom' $false

    if (-not $ready) {
        Write-AppLog 'ERROR' "Tempo limite ($($c.HeadroomTimeoutSec)s) esgotado aguardando o Headroom ficar pronto."
        if (-not [string]::IsNullOrWhiteSpace($lastDetail)) {
            Write-AppLog 'DIAG' "Ultimo estado reportado: $lastDetail"
        }
        return $false
    }
    return $true
}

# ------------------------------------------------------------------------------
# ETAPA 2: HERMES
# ------------------------------------------------------------------------------
function Test-HermesSetup {
    $c = $global:AiCfg
    $r = [pscustomobject]@{
        ExePath     = $null
        ConfigPath  = $c.HermesConfigPath
        ConfigFound = $false
        EnvPath     = $c.HermesEnvPath
        EnvFound    = $false
        BaseUrlOk   = $false
        ModelOk     = $false
        WorkDirOk   = (Test-Path -LiteralPath $c.HermesWorkDir -PathType Container)
    }

    $exe = $c.HermesExePrimary
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        $r.ExePath = $exe
    } else {
        $fallback = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'hermes\bin\hermes.exe'
        if (Test-Path -LiteralPath $fallback -PathType Leaf) { $r.ExePath = $fallback }
        else {
            $cmd = Get-Command -Name 'hermes' -ErrorAction SilentlyContinue
            if ($null -ne $cmd) { $r.ExePath = $cmd.Source }
        }
    }

    if (Test-Path -LiteralPath $r.ConfigPath -PathType Leaf) {
        $r.ConfigFound = $true
        try {
            $raw = [System.IO.File]::ReadAllText($r.ConfigPath, [System.Text.Encoding]::UTF8)
            $r.BaseUrlOk = $raw.Contains($c.NvidiaBaseUrl) -or $raw.Contains($c.HeadroomBaseUrl)
            $r.ModelOk = $raw.Contains($c.HermesExpectedModel)
            $raw = $null
        } catch { }
    }

    if (Test-Path -LiteralPath $r.EnvPath -PathType Leaf) {
        $r.EnvFound = $true
    }

    return $r
}

function Start-HermesTerminal {
    param([switch]$Force)
    $c = $global:AiCfg

    $h = Get-HeadroomHealth -BaseUrl $c.HeadroomBaseUrl
    if (-not $h.Ready) {
        Write-AppLog 'ERROR' "O Headroom nao esta saudavel ($($h.Detail)). O Hermes so pode ser aberto depois que o Headroom estiver pronto."
        return $false
    }

    $s = Test-HermesSetup
    if ([string]::IsNullOrWhiteSpace($s.ExePath)) {
        Write-AppLog 'ERROR' "Executavel do Hermes CLI nao encontrado em: $($c.HermesExePrimary)"
        return $false
    }
    if (-not $s.ConfigFound) {
        Write-AppLog 'ERROR' "Arquivo config.yaml do Hermes nao encontrado em: $($s.ConfigPath)"
        return $false
    }
    if (-not $s.WorkDirOk) {
        Write-AppLog 'ERROR' "Diretorio de trabalho nao encontrado: $($c.HermesWorkDir)"
        return $false
    }

    if (-not $Force) {
        $running = @(Get-HermesProcess)
        if ($running.Count -gt 0) {
            Write-AppLog 'WARN' "O Hermes ja esta em execucao (PID $($running[0].Id)). Nenhuma nova janela sera aberta."
            return $true
        }
    }

    $exe = $s.ExePath
    $wd = $c.HermesWorkDir
    $launchCmd = "cd /d `"$wd`" && echo Ambiente ativo: Hermes -^> Headroom ($($c.HeadroomPort)) -^> NVIDIA NIM via $($c.NvidiaBaseUrl) && `"$exe`""
    try {
        Start-ManagedTerminalWindow -WindowTitle 'HERMES - PROJETOS' -WorkingDirectory $wd -CommandLine $launchCmd -WindowStyle Normal
    } catch {
        Write-AppLog 'ERROR' "Falha ao abrir o Hermes: $($_.Exception.Message)"
        return $false
    }
    Write-AppLog 'OK' "Hermes aberto em $wd."
    return $true
}

# ------------------------------------------------------------------------------
# PARADA SELETIVA DE PROCESSOS
# ------------------------------------------------------------------------------
function Stop-AiEnvironment {
    # Encerra apenas processos iniciados pelo AmbienteIA (rastreados por PID).
    $procs = Get-ManagedProcesses
    $count = 0
    foreach ($p in $procs) {
        try {
            Write-AppLog 'INFO' "Encerrando processo gerenciado (PID $($p.Id), $($p.ProcessName))."
            $p.CloseMainWindow()
            if (-not $p.WaitForExit(5000)) { $p.Kill() }
            $count++
        } catch {
            Write-AppLog 'WARN' "Nao foi possivel encerrar o PID $($p.Id): $($_.Exception.Message)"
        }
    }
    $script:AiManagedPids = @()
    Write-AppLog 'OK' "$count processo(s) gerenciado(s) encerrado(s)."
    return $count
}

# ------------------------------------------------------------------------------
# TESTES PONTUAIS
# ------------------------------------------------------------------------------
function Test-NvidiaConnection {
    # Testa conectividade com o endpoint NVIDIA NIM (somente leitura).
    $c = $global:AiCfg
    $probe = Invoke-HttpProbe -Url "$($c.NvidiaNimEndpoint)/models" -TimeoutMs 5000
    $r = [pscustomobject]@{ Ok = $false; Status = $probe.Status; Detail = ''; Error = $probe.Error }
    if ($probe.Status -ge 200 -and $probe.Status -lt 400) {
        $r.Ok = $true
        $r.Detail = "Endpoint NVIDIA NIM respondeu HTTP $($probe.Status)."
    } elseif ($probe.Status -eq 0) {
        $r.Detail = "Sem resposta do endpoint NVIDIA NIM: $($probe.Error)"
    } else {
        $r.Detail = "Endpoint NVIDIA NIM respondeu HTTP $($probe.Status) (pode exigir autenticacao)."
    }
    return $r
}

function Test-Headroom {
    # Teste pontual do Headroom (somente leitura).
    $c = $global:AiCfg
    $h = Get-HeadroomHealth -BaseUrl $c.HeadroomBaseUrl
    $stats = Get-HeadroomStats -BaseUrl $c.HeadroomBaseUrl
    $r = [pscustomobject]@{
        State   = $h.State
        Livez   = $h.LivezStatus
        Readyz  = $h.ReadyzStatus
        Upstream= $h.UpstreamStatus
        Version = $h.Version
        Detail  = $h.Detail
        Ready   = $h.Ready
        Stats   = $stats
    }
    return $r
}

function Get-AiStatsSummary {
    # Extrai metricas relevantes do /stats para exibicao na UI.
    $stats = Get-HeadroomStats
    if ($null -eq $stats) { return $null }

    $s = $stats.summary

    # Requisicoes: tenta api_requests primeiro, depois totais.requests
    $reqCount = 0
    if ($s.PSObject.Properties.Name -contains 'api_requests') {
        $reqCount = [int]$s.api_requests
    } elseif ($s.totals -and $s.totals.PSObject.Properties.Name -contains 'requests') {
        $reqCount = [int]$s.totals.requests
    }

    $tokens = $stats.tokens
    $latency = $stats.latency

    $failedReqs = 0
    if ($s.requests -and $s.requests.PSObject.Properties.Name -contains 'failed') {
        $failedReqs = [int]$s.requests.failed
    }

    $avgLatency = 0
    if ($latency -and $latency.PSObject.Properties.Name -contains 'average_ms') {
        $avgLatency = [double]$latency.average_ms
    }

    $tokensSaved = 0
    if ($tokens -and $tokens.PSObject.Properties.Name -contains 'saved') {
        $tokensSaved = [int]$tokens.saved
    }

    $savingsPct = 0
    if ($tokens -and $tokens.PSObject.Properties.Name -contains 'active_savings_percent') {
        $savingsPct = [double]$tokens.active_savings_percent * 100
    }

    # Modelo: tenta do primary_model do summary
    $model = $global:AiCfg.HermesExpectedModel
    if ($s.PSObject.Properties.Name -contains 'primary_model' -and -not [string]::IsNullOrWhiteSpace($s.primary_model)) {
        $model = [string]$s.primary_model
    }

    return [pscustomobject]@{
        Requests         = $reqCount
        TokensSaved      = $tokensSaved
        TokensBefore     = if ($tokens -and $tokens.PSObject.Properties.Name -contains 'total_before_compression') { [int]$tokens.total_before_compression } else { 0 }
        AvgLatencyMs     = [math]::Round($avgLatency, 1)
        FailedRequests   = $failedReqs
        Provider         = 'NVIDIA NIM'
        Model            = $model
        TokensSavedPct   = [math]::Round($savingsPct, 2)
    }
}

# ------------------------------------------------------------------------------
# FLUXOS DE ALTO NIVEL
# ------------------------------------------------------------------------------
function Start-AiEnvironment {
    try {
        Set-AiState 'Progress' 5
        Set-AiState 'Phase' 'Inicializando Headroom'
        if (Test-AdminContext) {
            Write-AppLog 'WARN' 'O aplicativo esta rodando como administrador. Isso nao e necessario nem recomendado.'
        }

        Write-AppLog 'INFO' 'Inicializando Headroom...'
        if (-not (Test-True (Start-HeadroomStep))) {
            Set-AiState 'Phase' 'Falha no Headroom'
            Write-AppLog 'ERROR' 'Ambiente nao iniciado: Headroom indisponivel.'
            return $false
        }
        Write-AppLog 'OK' 'Headroom saudavel.'
        Set-AiState 'Progress' 60

        Set-AiState 'Phase' 'Inicializando Hermes'
        Write-AppLog 'INFO' 'Inicializando Hermes...'
        if (-not (Test-True (Start-HermesTerminal))) {
            Set-AiState 'Phase' 'Falha no Hermes'
            Write-AppLog 'ERROR' 'Headroom esta pronto, mas o Hermes nao pôde ser aberto.'
            return $false
        }

        Set-AiState 'Progress' 100
        Set-AiState 'Phase' 'Ambiente pronto'
        Write-AppLog 'OK' 'Ambiente pronto.'
        return $true
    } catch {
        Write-AppLog 'ERROR' "Erro inesperado durante a inicializacao: $($_.Exception.Message)"
        Set-AiState 'Phase' 'Erro inesperado'
        return $false
    } finally {
        Set-AiState 'WaitHeadroom' $false
    }
}

function Open-HermesOnly {
    try {
        Set-AiState 'Phase' 'Abrindo Hermes'
        Write-AppLog 'INFO' 'Abrindo Hermes...'
        $ok = Test-True (Start-HermesTerminal -Force)
        if ($ok) { Set-AiState 'Phase' 'Hermes aberto' } else { Set-AiState 'Phase' 'Hermes nao aberto' }
        return $ok
    } catch {
        Write-AppLog 'ERROR' "Erro inesperado ao abrir o Hermes: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-AiDiagnostics {
    # Diagnostico SOMENTE LEITURA. Nao inicia, nao encerra e nao altera nada.
    $c = $global:AiCfg
    $root = $global:AiRoot
    $counts = @{ Ok = 0; Warn = 0; Err = 0; Nt = 0 }

    $note = {
        param([string]$Level, [string]$Msg, [string]$Solution = '')
        switch ($Level) {
            'OK'    { $counts.Ok++ }
            'WARN'  { $counts.Warn++ }
            'ERROR' { $counts.Err++ }
            'NÃO TESTADO' { $counts.Nt++ }
        }
        $line = $Msg
        if (-not [string]::IsNullOrWhiteSpace($Solution)) { $line += " | Solucao: $Solution" }
        Write-AppLog $Level $line
    }

    try {
        Set-AiState 'Phase' 'Executando diagnostico'
        Write-AppLog 'INFO' 'Iniciando diagnostico (somente leitura)...'

        # Contexto do sistema
        Write-AppLog 'INFO' '--- Sistema ---'
        $os = [Environment]::OSVersion.VersionString
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        & $note 'OK' "Windows: $os (arquitetura $arch)"
        & $note 'OK' "PowerShell $($PSVersionTable.PSVersion)"
        if (Test-AdminContext) { & $note 'WARN' 'Executando como administrador (nao recomendado).' } else { & $note 'OK' 'Executando sem privilégios de administrador.' }

        # Diretorios necessários
        Write-AppLog 'INFO' '--- Diretorios e permissoes ---'
        $dirsToCheck = @(
            @{ Path = $c.HermesWorkDir; Label = 'Diretorio de trabalho (C:\Projetos)' }
            @{ Path = (Split-Path -Parent $c.HermesConfigPath); Label = 'Diretorio de configuracao do Hermes' }
            @{ Path = (Split-Path -Parent $c.HermesEnvPath); Label = 'Diretorio de variaveis de ambiente (.env)' }
            @{ Path = (Split-Path -Parent $c.HermesExePrimary); Label = 'Diretorio do executavel Hermes' }
            @{ Path = (Split-Path -Parent (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Python\pythoncore-3.14-64\python.exe')); Label = 'Diretorio do Python com Headroom' }
        )
        foreach ($d in $dirsToCheck) {
            if (Test-Path -LiteralPath $d.Path -PathType Container) {
                $writable = $true
                try { $t = Join-Path $d.Path '._ai_write_test'; [System.IO.File]::WriteAllText($t, 'test'); [System.IO.File]::Delete($t) } catch { $writable = $false }
                if ($writable) { & $note 'OK' "$($d.Label): acessível e gravável." } else { & $note 'WARN' "$($d.Label): acessível, mas sem permissão de gravação." }
            } else {
                & $note 'ERROR' "$($d.Label): não encontrado ($($d.Path)). | Solução: Crie o diretório ou corrija o caminho no Core."
            }
        }

        # Python e Headroom
        Write-AppLog 'INFO' '--- Python e Headroom ---'
        $pyExe = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Python\pythoncore-3.14-64\python.exe'
        if (Test-Path -LiteralPath $pyExe -PathType Leaf) {
            & $note 'OK' "Python encontrado: $pyExe"
            $pyVersion = & $pyExe --version 2>$null
            if ($LASTEXITCODE -eq 0) { & $note 'OK' "Versao do Python: $pyVersion" } else { & $note 'WARN' 'Nao foi possível ler a versão do Python.' }
        } else {
            & $note 'ERROR' "Python não encontrado em: $pyExe | Solução: Instale o Python ou corrija o caminho no Core."
        }

        $headroomExe = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Python\pythoncore-3.14-64\Scripts\headroom.exe'
        if (Test-Path -LiteralPath $headroomExe -PathType Leaf) {
            & $note 'OK' "Executável Headroom encontrado: $headroomExe"
        } else {
            & $note 'ERROR' "Executável Headroom não encontrado em: $headroomExe | Solução: Instale o Headroom (pip install headroom-proxy)."
        }

        $py = Resolve-HeadroomPython -ManualPython $c.HeadroomPythonManual -WorkDir $c.HermesWorkDir
        if ($null -eq $py) {
            & $note 'ERROR' "Nenhum Python com 'headroom.cli proxy' funcional foi encontrado."
        } else {
            & $note 'OK' "Python com Headroom: $($py.PythonExe)"
            if ($py.Version -eq $c.HeadroomExpectedVersion) { & $note 'OK' "Versão do Headroom: $($py.Version)." }
            else { & $note 'WARN' "Versão do Headroom é '$($py.Version)' (esperada: $($c.HeadroomExpectedVersion))." }
        }

        $hrProcs = @(Get-HeadroomProcess)
        if ($hrProcs.Count -gt 0) { & $note 'OK' "Processo(s) do Headroom em execução: $($hrProcs.Count)." }
        else { & $note 'WARN' 'Nenhum processo do Headroom em execução.' }
        if ($hrProcs.Count -gt 1) { & $note 'WARN' 'Há mais de um processo do Headroom; pode haver instância duplicada.' }

        if (Test-TcpPortOpen -TargetHost $c.HeadroomHost -Port $c.HeadroomPort -TimeoutMs 800) {
            & $note 'OK' "Porta $($c.HeadroomPort) aberta."
        } else {
            & $note 'WARN' "Porta $($c.HeadroomPort) fechada. | Solução: Inicie o AmbienteIA para subir o Headroom."
        }

        $h = Get-HeadroomHealth -BaseUrl $c.HeadroomBaseUrl
        if ($h.LivezStatus -eq 200) { & $note 'OK' "/livez respondeu HTTP 200." }
        else { & $note 'WARN' "/livez sem sucesso ($($h.Detail)). | Solução: Inicie o Headroom." }

        if ($h.ReadyzStatus -eq 200) { & $note 'OK' "/readyz respondeu HTTP 200." }
        elseif ($h.LivezStatus -eq 200) { & $note 'WARN' "/readyz sem sucesso ($($h.Detail))." }

        if ($h.Ready) { & $note 'OK' "Headroom saudável (upstream=$($h.UpstreamStatus), v$($h.Version))." }
        else { & $note 'WARN' 'Headroom não está pronto.' }

        # Hermes
        Write-AppLog 'INFO' '--- Hermes ---'
        $s = Test-HermesSetup
        if ($s.ExePath) { & $note 'OK' "Executável: $($s.ExePath)" }
        else { & $note 'ERROR' "Executável não encontrado em $($c.HermesExePrimary). | Solução: Verifique a instalação do Hermes Agent." }

        if ($s.ConfigFound) { & $note 'OK' "config.yaml encontrado: $($s.ConfigPath)" }
        else { & $note 'ERROR' "config.yaml não encontrado: $($s.ConfigPath). | Solução: Execute 'hermes config setup' ou crie o arquivo." }

        if ($s.ConfigFound) {
            if ($s.BaseUrlOk) { & $note 'OK' "config.yaml referencia o endpoint local do Headroom/NVIDIA." }
            else { & $note 'WARN' "config.yaml não referencia $($c.NvidiaBaseUrl). | Solução: Defina NVIDIA_BASE_URL no config.yaml do Hermes." }
            if ($s.ModelOk) { & $note 'OK' "Modelo '$($c.HermesExpectedModel)' presente no config.yaml." }
            else { & $note 'WARN' "Modelo '$($c.HermesExpectedModel)' não encontrado no config.yaml. | Solução: Defina o modelo padrão no config.yaml do Hermes." }
        }

        if ($s.EnvFound) { & $note 'OK' ".env encontrado: $($s.EnvPath)" }
        else { & $note 'WARN' ".env não encontrado: $($s.EnvPath). | Solução: Crie o .env com NVIDIA_API_KEY." }

        $hm = @(Get-HermesProcess)
        if ($hm.Count -gt 0) { & $note 'OK' "Hermes em execução ($($hm.Count) processo(s))." }
        else { Write-AppLog 'INFO' 'Hermes não está em execução.' }

        # NVIDIA NIM
        Write-AppLog 'INFO' '--- NVIDIA NIM ---'
        $nv = Test-NvidiaConnection
        if ($nv.Ok) { & $note 'OK' "$($nv.Detail)" }
        else { & $note 'WARN' "$($nv.Detail) | Solução: Verifique a conexão com a internet e a chave NVIDIA_API_KEY no .env." }

        # Modelo configurado
        Write-AppLog 'INFO' '--- Modelo configurado ---'
        & $note 'OK' "Modelo padrão: $($c.HermesExpectedModel)"
        & $note 'OK' "NVIDIA_BASE_URL: $($c.NvidiaBaseUrl)"
        & $note 'OK' "Endpoint NVIDIA NIM: $($c.NvidiaNimEndpoint)"

        # Assets
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            Write-AppLog 'INFO' '--- Assets da interface ---'
            foreach ($img in @('hermes.png', 'headroom.png', 'nvidia.png')) {
                if (Test-Path -LiteralPath (Join-Path (Join-Path $root 'Assets') $img) -PathType Leaf) {
                    & $note 'OK' "Assets\\$img presente."
                } else {
                    & $note 'WARN' "Assets\\$img ausente (a interface continua funcionando sem a imagem)."
                }
            }
        }

        $summaryLevel = 'OK'
        if ($counts.Warn -gt 0) { $summaryLevel = 'WARN' }
        if ($counts.Err -gt 0) { $summaryLevel = 'ERROR' }
        Write-AppLog $summaryLevel "Diagnostico concluído: $($counts.Ok) OK, $($counts.Warn) aviso(s), $($counts.Err) erro(s), $($counts.Nt) não testado(s)."
        Set-AiState 'Phase' 'Diagnóstico concluído'
        return [pscustomobject]@{ Ok = $counts.Ok; Warnings = $counts.Warn; Errors = $counts.Err; NotTested = $counts.Nt }
    } catch {
        Write-AppLog 'ERROR' "Erro inesperado no diagnostico: $($_.Exception.Message)"
        return [pscustomobject]@{ Ok = 0; Warnings = 0; Errors = 1; NotTested = 0 }
    }
}