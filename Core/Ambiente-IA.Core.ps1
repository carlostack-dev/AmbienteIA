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
    HeadroomSubcommand     = '-m headroom.cli proxy --port 8787 --mode cache --openai-api-url "https://integrate.api.nvidia.com/v1" --provider-name "NVIDIA NIM"'
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

# ------------------------------------------------------------------------------
# CARREGAMENTO DE CREDENCIAIS DO .ENV (sem exposicao de segredos)
# ------------------------------------------------------------------------------
function Load-EnvFile {
    param([string]$EnvPath)
    if ([string]::IsNullOrWhiteSpace($EnvPath)) { return @{} }
    if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) { return @{} }

    $vars = @{}
    try {
        $content = [System.IO.File]::ReadAllLines($EnvPath, [System.Text.Encoding]::UTF8)
        foreach ($line in $content) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
            if ($trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                $key = $matches[1]
                $value = $matches[2]
                # Remover aspas ao redor do valor
                if ($value -match '^"(.*)"$') { $value = $matches[1] }
                elseif ($value -match "''(.*)''") { $value = $matches[1] }
                $vars[$key] = $value
            }
        }
    } catch {
        Write-AppLog 'WARN' "Nao foi possivel ler o arquivo .env: $EnvPath"
    }
    return $vars
}

function Set-AiEnvironmentVariables {
    $c = $global:AiCfg

    # 1. Carregar .env do Hermes (fonte de verdade da NVIDIA_API_KEY)
    $envVars = Load-EnvFile -EnvPath $c.HermesEnvPath

    if ($envVars.ContainsKey('NVIDIA_API_KEY')) {
        $env:NVIDIA_API_KEY = $envVars['NVIDIA_API_KEY']
        Write-AppLog 'OK' 'NVIDIA_API_KEY carregada do .env (valor mascarado nos logs).'
    } else {
        Write-AppLog 'WARN' 'NVIDIA_API_KEY nao encontrada no .env do Hermes.'
    }

    # 2. OPENAI_API_KEY recebe o valor de NVIDIA_API_KEY para compatibilidade com o proxy
    if ($env:NVIDIA_API_KEY) {
        $env:OPENAI_API_KEY = $env:NVIDIA_API_KEY
        Write-AppLog 'OK' 'OPENAI_API_KEY definida a partir de NVIDIA_API_KEY.'
    }

    # 3. HERMES_HOME para o Hermes Agent (raiz da instalacao, nao a pasta bin/)
    $hermesHome = Split-Path -Parent $c.HermesEnvPath
    if (Test-Path -LiteralPath $hermesHome -PathType Container) {
        $env:HERMES_HOME = $hermesHome
        Write-AppLog 'OK' "HERMES_HOME definido: $hermesHome"
    } else {
        Write-AppLog 'WARN' "Diretorio HERMES_HOME nao encontrado: $hermesHome"
    }
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
        if ($null -ne $resp) { $resp.Close() }
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
    # Procura por hermes.exe direto e por python.exe rodando o wrapper do Headroom
    $procs = @(Get-Process -Name 'hermes' -ErrorAction SilentlyContinue)
    try {
        $wrapProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'python%'" -ErrorAction Stop |
            Where-Object {
                $_.CommandLine -and $_.CommandLine -like '*headroom.cli*wrap*hermes*'
            })
        foreach ($p in $wrapProcs) {
            if ($procs -notcontains $p) { $procs += $p }
        }
    } catch { }
    return $procs
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
# LISTA COMPARTILHADA ENTRE RUNARSPACES: a GUI roda no runspace principal e
# Start-AiEnvironment roda em um runspace de background (Start-BackgroundWork).
# O escopo $script: e' isolado por runspace, entao os PIDs registrados no
# background nunca seriam vistos pela GUI. Usamos $global: com uma Lista
# tipada, que e' a mesma instancia em ambos os runspaces (passada via
# SessionStateProxy.SetVariable em New-BackgroundRunspace).
if (-not ($global:AiManagedPids -is [System.Collections.Generic.List[int]])) {
    $global:AiManagedPids = [System.Collections.Generic.List[int]]::new()
}

# Identificador unico da sessao atual da interface. Usado para nao confundir
# processos de sessoes anteriores com o da sessao em execucao.
if (-not ($global:AiSessionId -is [string] -and -not [string]::IsNullOrWhiteSpace($global:AiSessionId))) {
    $global:AiSessionId = [Guid]::NewGuid().ToString('N')
}

# Metadados compartilhados entre runspaces: PID -> { CommandLine, CreateTime, ParentPid, Executable, Kind }.
# Permite validar propriedade do processo (evitar PID reutilizado pelo Windows)
# e encerrar a arvore completa de descendentes ao parar o ambiente.
if (-not ($global:AiManagedProcessMeta -is [System.Collections.Hashtable])) {
    $global:AiManagedProcessMeta = [System.Collections.Hashtable]::Synchronized([System.Collections.Hashtable]::new())
}

# Arvore de parentesco: PaiPid -> Lista[int] de PIDs filhos diretos.
# Preenchido ao lançar janelas e ao mapear descendentes existentes.
if (-not ($global:AiProcessTree -is [System.Collections.Hashtable])) {
    $global:AiProcessTree = [System.Collections.Hashtable]::Synchronized([System.Collections.Hashtable]::new())
}

# ------------------------------------------------------------------------------
# REGISTRO PERSISTENTE DE PROCESSOS (recuperacao apos encerramento abrupto)
# ------------------------------------------------------------------------------
# Arquivo JSON que persiste os metadados dos processos iniciados pelo
# AmbienteIA. Permite recuperar processos órfãos de sessoes anteriores mesmo
# quando a interface foi encerrada abruptamente (sem passar por Stop-AiEnvironment).
if (-not ($script:AiRegisteredProcessesFile -is [string] -and -not [string]::IsNullOrWhiteSpace($script:AiRegisteredProcessesFile))) {
    $script:AiRegisteredProcessesFile = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'AmbienteIA\hermes\ai_registered_processes.json'
}

function Save-RegisteredProcessesToDisk {
    try {
        $snapshot = [System.Collections.Generic.List[object]]::new()
        foreach ($managedPid in @($global:AiManagedPids)) {
            if ($global:AiManagedProcessMeta.ContainsKey($managedPid)) {
                $meta = $global:AiManagedProcessMeta[$managedPid]
                # Serializa CreateTime como string ISO 8601 para evitar o formato
                # \/Date(...)\/ do ConvertTo-Json, nao suportado pelo
                # ConvertFrom-Json do PowerShell 5.1.
                $entry = [ordered]@{
                    Pid           = $meta.Pid
                    CommandLine   = [string]$meta.CommandLine
                    CreateTime    = if ($meta.CreateTime -is [datetime]) {
                        ([datetime]$meta.CreateTime).ToString('o')
                    } else {
                        [string]$meta.CreateTime
                    }
                    ParentPid     = $meta.ParentPid
                    Executable    = [string]$meta.Executable
                    Kind          = [string]$meta.Kind
                    SessionId     = [string]$meta.SessionId
                }
                $snapshot.Add($entry)
            }
        }
        $json = $snapshot | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($script:AiRegisteredProcessesFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-AppLog 'WARN' "Nao foi possivel salvar o registro persistente de processos: $($_.Exception.Message)"
    }
}

function Load-RegisteredProcessesFromDisk {
    if (-not (Test-Path -LiteralPath $script:AiRegisteredProcessesFile -PathType Leaf)) { 
        Write-Host "[DEBUG Load] Arquivo nao encontrado" -ForegroundColor Yellow
        return @() 
    }
    try {
        $content = [System.IO.File]::ReadAllText($script:AiRegisteredProcessesFile, (New-Object System.Text.UTF8Encoding($false)))
        $data = $content | ConvertFrom-Json
        if ($null -eq $data) { 
            Write-Host "[DEBUG Load] data e null" -ForegroundColor Yellow
            return @() 
        }
        # Garante que retorne sempre um array (ConvertFrom-Json retorna objeto unico com 1 item).
        $arr = @($data)
        Write-Host "[DEBUG Load] arr.Count=$($arr.Count)" -ForegroundColor Yellow
        return $arr
    } catch {
        Write-AppLog 'WARN' "Nao foi possível carregar o registro persistente de processos: $($_.Exception.Message)"
        return @()
    }
}

# Retorna processos registrados em disco que pertencem a SESSOES ANTERIORES
# (SessionId diferente da atual) e que ainda existem no SO.
# Usado apenas para identificacao segura de órfãos; nao encerra por si so.
function Get-RegisteredProcessesFromPriorSessions {
    $prior = @()
    foreach ($entry in Load-RegisteredProcessesFromDisk) {
        try {
            $managedPid = [int]$entry.Pid
            if ($managedPid -le 0) { continue }
            # So considera sessao anterior se o SessionId for diferente da atual.
            if ([string]$entry.SessionId -eq $global:AiSessionId) { continue }
            $p = Get-Process -Id $managedPid -ErrorAction SilentlyContinue
            if ($null -eq $p) { continue }
            # Valida identidade antes de considerar como pertencente a sessao anterior.
            $ct = [datetime]$entry.CreateTime
            if ($ct -ne $p.StartTime) { continue }
            $exeName = Split-Path -Leaf $p.Path
            $regExe = [string]$entry.Executable
            if (-not [string]::IsNullOrWhiteSpace($regExe) -and $exeName -ne (Split-Path -Leaf $regExe)) { continue }
            $prior += [pscustomobject]@{
                Pid           = $managedPid
                CommandLine   = [string]$entry.CommandLine
                CreateTime    = $ct
                ParentPid     = [int]$entry.ParentPid
                Executable    = [string]$entry.Executable
                Kind          = [string]$entry.Kind
                SessionId     = [string]$entry.SessionId
                Process       = $p
            }
        } catch { }
    }
    return $prior
}

function Remove-RegisteredProcess {
    param([int]$ProcessId)
    if ($global:AiManagedPids.Contains($ProcessId)) {
        $global:AiManagedPids.Remove($ProcessId)
    }
    if ($global:AiManagedProcessMeta.Contains($ProcessId)) {
        $global:AiManagedProcessMeta.Remove($ProcessId)
    }
    Save-RegisteredProcessesToDisk
}

function Register-ManagedProcess {
    param(
        [int]$processId,
        [string]$CommandLine,
        [datetime]$CreateTime,
        [int]$ParentPid,
        [string]$Executable,
        [string]$Kind
    )
    if ($processId -le 0) { return }
    if (-not $global:AiManagedPids.Contains($processId)) {
        $global:AiManagedPids.Add($processId)
    }
    $meta = [ordered]@{
        Pid           = $processId
        CommandLine   = $CommandLine
        CreateTime    = $CreateTime
        ParentPid     = $ParentPid
        Executable    = $Executable
        Kind          = $Kind
        SessionId     = $global:AiSessionId
    }
    $global:AiManagedProcessMeta[$processId] = $meta
    if ($ParentPid -gt 0) {
        if (-not $global:AiProcessTree.ContainsKey($ParentPid)) {
            $global:AiProcessTree[$ParentPid] = [System.Collections.Generic.List[int]]::new()
        }
        $children = $global:AiProcessTree[$ParentPid]
        if (-not $children.Contains($processId)) { $children.Add($processId) }
    }
    # Persiste o registro para recuperacao apos encerramento abrupto.
    Save-RegisteredProcessesToDisk
}

function Get-ManagedProcesses {
    $alive = @()
    # Snapshot: evita enumerar a lista compartilhada enquanto outro runspace a altera.
    foreach ($processId in @($global:AiManagedPids)) {
        try {
            $p = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($null -ne $p) { $alive += $p }
        } catch { }
    }
    return $alive
}

# ------------------------------------------------------------------------------
# DESCOBERTA DE PROCESSOS FILHOS E POR TÍTULO DE JANELA
# ------------------------------------------------------------------------------
# Encontra processos filhos de um PID pai usando WMI (Win32_Process).
# Isso permite encerrar não apenas o cmd.exe pai, mas também os
# processos python.exe (Headroom / Hermes) que ele gerou.
function Get-ChildProcesses {
    param([int]$ParentPid)
    $children = @()
    try {
        $wmiProcs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object { $_.ParentProcessId -eq $ParentPid })
        foreach ($c in $wmiProcs) {
            try {
                $p = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue
                if ($null -ne $p) { $children += $p }
            } catch { }
        }
    } catch { }
    return $children
}

# ------------------------------------------------------------------------------
# PERCURSO RECURSIVO DA ARVORE DE PROCESSOS
# ------------------------------------------------------------------------------
# Retorna todos os descendentes (netos, bisnetos, ...) de um PID raiz,
# percorrendo Win32_Process ate nao ha mais filhos. Usado para encerrar a
# arvore completa pertencente a uma janela cmd lancada pelo AmbienteIA.
function Get-DescendantProcessesRecursive {
    param([int]$RootPid)
    $all = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootPid)
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    try {
        $allProcs = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    } catch {
        return $all
    }
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($c in $allProcs) {
            try {
                if ([int]$c.ParentProcessId -eq $current -and -not $seen.Contains([int]$c.ProcessId)) {
                    $seen.Add([int]$c.ProcessId) | Out-Null
                    $p = Get-Process -Id ([int]$c.ProcessId) -ErrorAction SilentlyContinue
                    if ($null -ne $p) {
                        $all.Add($p)
                        $queue.Enqueue([int]$c.ProcessId)
                    }
                }
            } catch { }
        }
    }
    return $all
}

# ------------------------------------------------------------------------------
# VALIDACAO DE PROPRIEDADE DE PROCESSO (evitar PID reutilizado)
# ------------------------------------------------------------------------------
# Um processo so e considerado gerenciado pela sessao atual se:
#  1. Seu PID esta em $global:AiManagedProcessMeta;
#  2. O CreateTime gravado coincide com o CreateTime real do processo;
#  3. O nome do executavel gravado coincide com o nome real;
#  4. O SessionId gravado coincide com a sessao atual.
# Isso impede encerrar um processo alheio que reaproveitou um PID antigo.
function Test-ProcessBelongsToCurrentSession {
    param([int]$ProcessId)
    if (-not $global:AiManagedProcessMeta.ContainsKey($ProcessId)) { return $false }
    $meta = $global:AiManagedProcessMeta[$ProcessId]
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($meta.SessionId) -or $meta.SessionId -ne $global:AiSessionId) { return $false }
        if ([datetime]$meta.CreateTime -ne $p.StartTime) { return $false }
        $exeName = Split-Path -Leaf $p.Path
        if (-not [string]::IsNullOrWhiteSpace($meta.Executable) -and
            $exeName -ne (Split-Path -Leaf $meta.Executable)) { return $false }
        return $true
    }    catch {
        return $false
    }
}

# ------------------------------------------------------------------------------
# VALIDACAO DE IDENTIDADE DE INSTANCIA DE PROCESSO (evitar PID reutilizado)
# ------------------------------------------------------------------------------
# Confirma que o processo com PID ainda e a mesma instancia registrada, comparando
# CreateTime, Executable e SessionId. O PID sozinho nao e suficiente porque o
# Windows reutiliza PIDs apos o encerramento de um processo.
# Retorna $true somente se todos os campos esperados (nao nulos/vazios) conferem.
function Test-ProcessIdentity {
    param([int]$ProcessId)
    # Lê os metadados esperados da variável de escopo, preenchida pelo chamador
    # imediatamente antes de solicitar o encerramento. Evita passar $null para
    # parâmetros nomeados (problema de vinculação no PowerShell 5.1).
    $expected = $null
    if ($script:ExpectedProcessIdentity -and $script:ExpectedProcessIdentity.Contains($ProcessId)) {
        $expected = $script:ExpectedProcessIdentity[$ProcessId]
    }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
    } catch {
        # Processo nao existe mais; ja foi encerrado. Nao e uma instancia valida.
        return $false
    }

    # 1. CreateTime deve coincidir (evita PID reutilizado por processo diferente).
    if ($null -ne $expected -and $null -ne $expected.CreateTime) {
        if ($p.StartTime -ne $expected.CreateTime) { return $false }
    }

    # 2. Executable deve coincidir, quando informado.
    if ($null -ne $expected -and -not [string]::IsNullOrWhiteSpace($expected.Executable)) {
        $exeName = Split-Path -Leaf $p.Path
        $regExeName = Split-Path -Leaf $expected.Executable
        if ($exeName -ne $regExeName) { return $false }
    }

    # 3. SessionId deve coincidir, quando informado. Get-Process nao expoe SessionId,
    #    entao consultamos o WMI para esse campo especifico.
    if ($null -ne $expected -and -not [string]::IsNullOrWhiteSpace($expected.SessionId)) {
        try {
            $wmi = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
            if ($null -ne $wmi -and [string]$wmi.SessionId -ne $expected.SessionId) { return $false }
        } catch { return $false }
    }

    return $true
}

# Retorna somente os processos rastreados que ainda pertencem a esta sessao.
function Get-ManagedProcessesCurrentSession {
    $alive = @()
    foreach ($processId in @($global:AiManagedPids)) {
        if (Test-ProcessBelongsToCurrentSession -ProcessId $processId) {
            try {
                $p = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($null -ne $p) { $alive += $p }
            } catch { }
        }
    }
    return $alive
}

# Retorna a arvore completa (raizes rastreadas + todos os descendentes) da
# sessao atual, sem duplicados e so com processos validados.
function Get-ManagedProcessTree {
    $roots = Get-ManagedProcessesCurrentSession
    $result = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($r in $roots) {
        if (-not $seen.Contains($r.Id)) { $seen.Add($r.Id) | Out-Null; $result.Add($r) }
        $desc = Get-DescendantProcessesRecursive -RootPid $r.Id
        foreach ($d in $desc) {
            if (-not $seen.Contains($d.Id)) { $seen.Add($d.Id) | Out-Null; $result.Add($d) }
        }
    }
    return $result
}

# Encontra processos cujo título de janela corresponde a um dos termos informados.
# Usado como camada de seguranca adicional para localizar janelas cmd.exe do
# Headroom ('HEADROOM - PROXY') e Hermes ('HERMES - PROJETOS') mesmo quando
# o PID nao esta mais no rastreamento em memoria.
function Find-ProcessesByWindowTitle {
    param([string[]]$TitleTerms)
    $found = @()
    try {
        $cmdProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction Stop)
        foreach ($c in $cmdProcs) {
            $title = [string]($c.CommandLine)
            foreach ($term in $TitleTerms) {
                if ($title -like "*$term*") {
                    try {
                        $p = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue
                        if ($null -ne $p) { $found += $p }
                    } catch { }
                    break
                }
            }
        }
    } catch { }
    return $found
}

# Encerra um processo individual de forma ordenada: tenta CloseMainWindow primeiro,
# aguarda, e só então usa Kill se necessário. Retorna $true se encerrou com sucesso.
function Stop-IndividualProcess {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$WaitMs = 5000
    )
    try {
        # $PID e' variavel automática (somente leitura) do PowerShell; nunca usar $pid como variavel local.
        $processId = $Process.Id
        $name = $Process.ProcessName

        # P6.3: Revalidar identidade da instancia antes de qualquer acao destrutiva.
        # Nao confiar apenas no PID nem em um objeto obtido anteriormente: o Windows
        # pode ter reutilizado o PID entre a validacao inicial e este ponto.
        # Os metadados esperados sao lidos de $script:ExpectedProcessIdentity,
        # preenchida pelo chamador imediatamente antes da solicitacao de encerramento.
        $expected = $null
        if ($script:ExpectedProcessIdentity -and $script:ExpectedProcessIdentity.Contains($processId)) {
            $expected = $script:ExpectedProcessIdentity[$processId]
        }
        if ($null -ne $expected) {
            if ($null -ne $expected.CreateTime -and $p.StartTime -ne $expected.CreateTime) {
                Write-AppLog 'WARN' "PID $processId ($name) CreateTime divergente na revalidacao pre-encerramento; abortando."
                return $false
            }
            if (-not [string]::IsNullOrWhiteSpace($expected.Executable)) {
                $exeName = Split-Path -Leaf $p.Path
                $regExeName = Split-Path -Leaf $expected.Executable
                if ($exeName -ne $regExeName) {
                    Write-AppLog 'WARN' "PID $processId ($name) Executable divergente na revalidacao pre-encerramento; abortando."
                    return $false
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($expected.SessionId)) {
                try {
                    $wmi = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
                    if ($null -ne $wmi -and [string]$wmi.SessionId -ne $expected.SessionId) {
                        Write-AppLog 'WARN' "PID $processId ($name) SessionId divergente na revalidacao pre-encerramento; abortando."
                        return $false
                    }
                } catch {
                    Write-AppLog 'WARN' "PID $processId ($name) nao foi possivel consultar WMI na revalidacao; abortando."
                    return $false
                }
            }
        }

        # Primeira tentativa: fechar janela principal (envia WM_CLOSE)
        $pClosed = $Process.CloseMainWindow()
        if (-not $pClosed) {
            # Sem janela principal ou não respondeu; vai direto para Kill
            Write-AppLog 'DIAG' "Processo PID $processId ($name) sem janela principal ou CloseMainWindow falhou; usando Kill."
        }
        if (-not $Process.WaitForExit($WaitMs)) {
            # Ainda vivo apos o tempo de espera; forca o encerramento.
            # P6.3: Revalidar identidade imediatamente antes do Kill (janela de reuso de PID).
            $expected = $null
            if ($script:ExpectedProcessIdentity -and $script:ExpectedProcessIdentity.Contains($processId)) {
                $expected = $script:ExpectedProcessIdentity[$processId]
            }
            if ($null -ne $expected) {
                if ($null -ne $expected.CreateTime -and $p.StartTime -ne $expected.CreateTime) {
                    Write-AppLog 'WARN' "PID $processId ($name) identidade divergente imediatamente antes do Kill; abortando."
                    return $false
                }
                if (-not [string]::IsNullOrWhiteSpace($expected.Executable)) {
                    $exeName = Split-Path -Leaf $p.Path
                    $regExeName = Split-Path -Leaf $expected.Executable
                    if ($exeName -ne $regExeName) {
                        Write-AppLog 'WARN' "PID $processId ($name) identidade divergente imediatamente antes do Kill; abortando."
                        return $false
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($expected.SessionId)) {
                    try {
                        $wmi = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
                        if ($null -ne $wmi -and [string]$wmi.SessionId -ne $expected.SessionId) {
                            Write-AppLog 'WARN' "PID $processId ($name) identidade divergente imediatamente antes do Kill; abortando."
                            return $false
                        }
                    } catch {
                        Write-AppLog 'WARN' "PID $processId ($name) nao foi possivel consultar WMI antes do Kill; abortando."
                        return $false
                    }
                }
            }
            $Process.Kill()
            $Process.WaitForExit(2000)
        }
        if ($Process.HasExited) {
            Write-AppLog 'OK' "Processo PID $processId ($name) encerrado."
            return $true
        }
        Write-AppLog 'WARN' "Processo PID $processId ($name) ainda está em execução após tentativa de encerramento."
        return $false
    } catch {
        Write-AppLog 'WARN' "Não foi possível encerrar o PID $($Process.Id): $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------------------------
# LANCAMENTO DE JANELAS DE TERMINAL
# ------------------------------------------------------------------------------
function Start-ManagedTerminalWindow {
    param(
        [string]$WindowTitle,
        [string]$WorkingDirectory,
        [string]$CommandLine,
        [ValidateSet('Normal', 'Minimized', 'Hidden')][string]$WindowStyle = 'Normal',
        [string]$Kind = 'terminal'
    )
    $cmdArgs = "/k title $WindowTitle && $CommandLine"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdArgs -WorkingDirectory $WorkingDirectory -WindowStyle $WindowStyle -PassThru
    try {
        $wmi = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction Stop
        $ct = if ($null -ne $wmi -and $wmi.CreationDate) {
            [System.Management.ManagementDateTimeConverter]::ToDateTime($wmi.CreationDate)
        } else { $proc.StartTime }
        $exe = Split-Path -Parent $proc.Path
    } catch {
        $ct = $proc.StartTime
        $exe = $proc.Path
    }
    Register-ManagedProcess -processId $proc.Id -CommandLine $proc.CommandLine -CreateTime $ct -ParentPid 0 -Executable $proc.Path -Kind $Kind
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
        $launchCmd = "echo Iniciando Headroom Proxy (upstream: $($c.NvidiaNimEndpoint))... && `"$pyExe`" $($c.HeadroomSubcommand)"
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
        $running = @(Get-ManagedHermesProcesses)
        if ($running.Count -gt 0) {
            Write-AppLog 'WARN' "O Hermes ja esta em execucao (PID $($running[0].Id)). Nenhuma nova janela sera aberta."
            return $true
        }
    }

    $exe = $s.ExePath
    $wd = $c.HermesWorkDir
    $launchCmd = "cd /d `"$wd`" && echo Ambiente ativo: Hermes -^> Headroom ($($c.HeadroomPort)) -^> NVIDIA NIM && python -m headroom.cli wrap hermes --no-proxy -- --provider openai"
    try {
        $cmdProc = Start-ManagedTerminalWindow -WindowTitle 'HERMES - PROJETOS' -WorkingDirectory $wd -CommandLine $launchCmd -WindowStyle Normal -Kind 'hermes-terminal'
    } catch {
        Write-AppLog 'ERROR' "Falha ao abrir o Hermes: $($_.Exception.Message)"
        return $false
    }

    # Confirmar que o Hermes realmente iniciou (aguardar o processo aparecer como descendente do CMD lancado nesta sessao).
    # Nao usa varredura global (Get-HermesProcess): aceita somente o processo filho/descendente do cmd que este
    # Start-HermesTerminal acabou de lancar, evitando confundir com um hermes.exe de sessao anterior.
    $hermesProc = $null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and $null -eq $hermesProc) {
        $descendants = @(Get-DescendantProcessesRecursive -RootPid $cmdProc.Id)
        foreach ($d in $descendants) {
            $dName  = $d.ProcessName
            $dCmd   = [string]$d.CommandLine
            # Hermes e': hermes.exe OU python.exe rodando 'headroom.cli wrap hermes', e deve ser descendente do CMD lancado.
            if (($dName -eq 'hermes') -or ($dName -like 'python*' -and $dCmd -like '*headroom.cli*wrap*hermes*')) {
                $hermesProc = $d
                break
            }
        }
        if ($null -eq $hermesProc) {
            Start-Sleep -Milliseconds 750
        }
    }

    if ($null -eq $hermesProc) {
        Write-AppLog 'WARN' 'Hermes foi lancado mas nao apareceu como descendente do CMD apos 15s. Pode ainda estar inicializando.'
        Write-AppLog 'OK' "Hermes aberto em $wd."
        return $true
    }

    # Registra o processo Hermes efetivamente iniciado (PID, CreateTime, Executable, ParentPid, Kind, SessionId).
    $processId = $hermesProc.Id
    $ct   = $hermesProc.StartTime
    $exe  = $hermesProc.Path
    try {
        Register-ManagedProcess -processId $processId -CommandLine $hermesProc.CommandLine -CreateTime $ct -ParentPid $cmdProc.Id -Executable $exe -Kind 'hermes'

        # Registra descendentes diretos do processo Hermes (netos do CMD), se houver.
        $hChildren = @(Get-ChildProcesses -ParentPid $processId)
        foreach ($hc in $hChildren) {
            Register-ManagedProcess -processId $hc.Id -CommandLine $hc.CommandLine -CreateTime $hc.StartTime -ParentPid $processId -Executable $hc.Path -Kind 'hermes-descendant'
        }
    } catch {
        Write-AppLog 'DIAG' 'Nao foi possivel registrar todos os descendentes do Hermes.'
    }

    # Confirmacao via registro da sessao atual (fonte de verdade do monitor de status).
    $confirmed = @(Get-ManagedHermesProcesses | Where-Object { $_.Id -eq $processId })
    if ($confirmed.Count -eq 0) {
        Write-AppLog 'WARN' "O processo Hermes (PID $processId) nao foi reconhecido pelo registro da sessao atual."
        Write-AppLog 'OK' "Hermes aberto em $wd."
        return $true
    }

    # Somente depois da validacao informa o PID correto do processo desta sessao.
    Write-AppLog 'OK' "Hermes iniciado (PID $processId)."
    Write-AppLog 'OK' "Hermes aberto em $wd."
    return $true
}

# ------------------------------------------------------------------------------
# PARADA SELETIVA DE PROCESSOS
# ------------------------------------------------------------------------------
function Stop-AiEnvironment {
    # Encerra apenas processos iniciados pelo AmbienteIA, comprovados por
    # registro persistente (PID + CreateTime + Executable + SessionId).
    # Nunca encerra por nome (hermes.exe, python.exe), titulo de janela ou
    # argumento --provider openai isoladamente. Nao encerra o Hermes Gateway.
    # Ordem: descendentes primeiro, depois raizes (cmd.exe).
    $stoppedCount = 0
    $stoppedFail  = 0
    $failedPids   = @()
    # Hashtable de escopo: PID -> {CreateTime, Executable, SessionId} esperados.
    # Usada por Stop-IndividualProcess para revalidar identidade antes de encerrar.
    $script:ExpectedProcessIdentity = New-Object System.Collections.Hashtable

    Write-AppLog 'INFO' 'Iniciando parada seletiva do ambiente...'

    # ------------------------------------------------------------------
    # 1. Processos da sessao atual (registro em memoria)
    # ------------------------------------------------------------------
    $currentTree = Get-ManagedProcessTree
    Write-AppLog 'INFO' "Processos da arvore da sessao atual: $($currentTree.Count)"

    $rootIds = @($global:AiManagedPids | Where-Object { Test-ProcessBelongsToCurrentSession -ProcessId $_ })

    # Encerra descendentes (nao-raizes) primeiro.
    foreach ($p in $currentTree) {
        if ($rootIds -contains $p.Id) { continue }
        # Validacao imediata de propriedade antes de encerrar.
        if (-not (Test-ProcessBelongsToCurrentSession -ProcessId $p.Id)) {
            Write-AppLog 'DIAG' "PID $($p.Id) nao pertence a esta sessao; pulando."
            continue
        }
        Write-AppLog 'INFO' "Encerrando descendente (PID $($p.Id), $($p.ProcessName))."
        if (Stop-IndividualProcess -Process $p -WaitMs 3000) { $stoppedCount++ }
        else { $stoppedFail++; $failedPids += $p.Id }
    }

    # Encerra raizes (cmd.exe) apos os descendentes.
    foreach ($managedPid in @($rootIds)) {
        try {
            $p = Get-Process -Id $managedPid -ErrorAction Stop
        } catch {
            # Ja nao existe mais.
            continue
        }
        # Validacao imediata de propriedade antes de encerrar.
        if (-not (Test-ProcessBelongsToCurrentSession -ProcessId $managedPid)) {
            Write-AppLog 'DIAG' "PID $managedPid nao pertence a esta sessao; pulando."
            continue
        }
        Write-AppLog 'INFO' "Encerrando raiz (PID $($p.Id), $($p.ProcessName))."
        if (Stop-IndividualProcess -Process $p -WaitMs 5000) { $stoppedCount++ }
        else { $stoppedFail++; $failedPids += $p.Id }
    }

    # ------------------------------------------------------------------
    # 2. Processos órfãos de sessoes anteriores (registro persistente em disco)
    # ------------------------------------------------------------------
    $priorSessions = Get-RegisteredProcessesFromPriorSessions
    Write-AppLog 'INFO' "Processos registrados de sessoes anteriores ainda ativos: $($priorSessions.Count)"

    foreach ($entry in $priorSessions) {
        $managedPid = $entry.Pid
        # Ignora se ja pertence a esta sessao (ja encerrado acima).
        if ($rootIds -contains $managedPid) { continue }

        # Validacao imediata e rigorosa: PID, CreateTime e Executable devem coincidir.
        $belongs = $false
        try {
            $p = Get-Process -Id $managedPid -ErrorAction Stop
            $ct = [datetime]$entry.CreateTime
            $exeName = Split-Path -Leaf $p.Path
            $regExe = [string]$entry.Executable
            if ($ct -eq $p.StartTime) {
                if ([string]::IsNullOrWhiteSpace($regExe) -or $exeName -eq (Split-Path -Leaf $regExe)) {
                    $belongs = $true
                }
            }
        } catch {
            # Processo nao existe mais; ja foi encerrado.
            continue
        }

        if (-not $belongs) {
            Write-AppLog 'DIAG' "PID $managedPid nao validado como orfao de sessao anterior; pulando."
            continue
        }

        Write-AppLog 'INFO' "Processo orfao de sessao anterior validado (PID $managedPid, $($entry.Process.ProcessName), comando: $($entry.CommandLine))."

        # Encerra descendentes do orfao primeiro.
        # P6.2: Revalidar identidade da raiz orfa antes de usar seu PID como referencia de parentesco.
        $script:ExpectedProcessIdentity[$managedPid] = @{
            CreateTime = $ct
            Executable = $regExe
            SessionId  = $entry.SessionId
        }
        $rootOk = Test-ProcessIdentity -ProcessId $managedPid
        if (-not $rootOk) {
            Write-AppLog 'DIAG' "Raiz orfa PID $managedPid nao revalidada; pulando arvore inteira."
            continue
        }

        # Obter todos os descendentes e montar mapa pai->filho via WMI.
        $allDesc = Get-DescendantProcessesRecursive -RootPid $managedPid
        $parentMap = New-Object System.Collections.Generic.HashSet[string]
        $pidCreateTime = New-Object System.Collections.Hashtable
        $pidSessionId = New-Object System.Collections.Hashtable
        $pidExecutable = New-Object System.Collections.Hashtable
        $pidCreateTime[$managedPid] = $ct
        $pidSessionId[$managedPid] = $entry.SessionId
        $pidExecutable[$managedPid] = $regExe

        foreach ($d in $allDesc) {
            try {
                $wmi = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($d.Id)" -ErrorAction SilentlyContinue
                if ($null -ne $wmi) {
                    $parentMap.Add("$($d.Id)|$([int]$wmi.ParentProcessId)") | Out-Null
                    $pidCreateTime[$d.Id] = $d.StartTime
                    $pidSessionId[$d.Id] = [string]$wmi.SessionId
                    $pidExecutable[$d.Id] = $d.Path
                }
            } catch { }
        }

        # P6.1: Ordem bottom-up (filhos antes de pais).
        $bottomUp = New-Object System.Collections.Generic.List[int]
        $processed = New-Object System.Collections.Generic.HashSet[int]
        $remaining = New-Object System.Collections.Generic.List[int]
        foreach ($d in $allDesc) { $remaining.Add($d.Id) }

        while ($remaining.Count -gt 0) {
            $progress = $false
            $nextRemaining = New-Object System.Collections.Generic.List[int]
            foreach ($procId in $remaining) {
                $pidStr = [string]$procId
                $parentPid = $null
                foreach ($entryMap in $parentMap) {
                    $parts = $entryMap.Split('|')
                    if ($parts[0] -eq $pidStr) { $parentPid = [int]$parts[1]; break }
                }
                if ($null -ne $parentPid -and ($parentPid -eq $managedPid -or $processed.Contains($parentPid))) {
                    $bottomUp.Add($procId) | Out-Null
                    $processed.Add($procId) | Out-Null
                    $progress = $true
                } else {
                    $nextRemaining.Add($procId)
                }
            }
            if (-not $progress) { break }
            $remaining = $nextRemaining
        }

        $validatedPids = New-Object System.Collections.Generic.HashSet[int]
        $validatedPids.Add($managedPid) | Out-Null

        foreach ($procId in $bottomUp) {
            $parentPid = $null
            foreach ($entryMap in $parentMap) {
                $parts = $entryMap.Split('|')
                if ($parts[0] -eq [string]$procId) { $parentPid = [int]$parts[1]; break }
            }
            if ($null -eq $parentPid -or -not $validatedPids.Contains($parentPid)) {
                Write-AppLog 'DIAG' "PID $procId nao possui pai imediato validado na arvore; pulando ramo."
                continue
            }

            $expCt = $pidCreateTime[$procId]
            $expExe = $pidExecutable[$procId]
            $expSess = $pidSessionId[$procId]
            if ([string]::IsNullOrWhiteSpace($expSess)) { $expSess = $entry.SessionId }

            # Definir metadados esperados para revalidacao dentro de Stop-IndividualProcess.
            $script:ExpectedProcessIdentity[$procId] = @{
                CreateTime = $expCt
                Executable = $expExe
                SessionId  = $expSess
            }

            if (-not (Test-ProcessIdentity -ProcessId $procId)) {
                Write-AppLog 'DIAG' "PID $procId identidade divergente na validacao de arvore; pulando ramo."
                continue
            }

            $parentCt = $pidCreateTime[$parentPid]
            $dp = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($null -eq $dp) { continue }
            if ($dp.StartTime -lt $parentCt) {
                Write-AppLog 'DIAG' "PID $procId anterior ao pai $parentPid; possivel reuso de PID; pulando."
                continue
            }

            $validatedPids.Add($procId) | Out-Null

            # P6.3: Stop-IndividualProcess revalida internamente (le $script:ExpectedProcessIdentity).
            if (Stop-IndividualProcess -Process $dp -WaitMs 3000) {
                $stoppedCount++
            } else {
                $stoppedFail++; $failedPids += $procId
            }
        }

        # Encerra o orfao (raiz da sessao anterior).
        if (Stop-IndividualProcess -Process $entry.Process -WaitMs 5000) { $stoppedCount++ }
        else { $stoppedFail++; $failedPids += $managedPid }
    }

    # ------------------------------------------------------------------
    # 3. Verificacao real de término
    # ------------------------------------------------------------------
    Start-Sleep -Milliseconds 1500
    $trueFailures = @()
    foreach ($processId in @($failedPids)) {
        try {
            $p = Get-Process -Id $processId -ErrorAction Stop
            $trueFailures += $processId
            Write-AppLog 'WARN' "FALHA ao encerrar PID $processId ($($p.ProcessName)) - processo ainda em execução apos todas as tentativas."
        } catch {
            # Nao existe mais: foi encerrado.
            $stoppedCount++
            $stoppedFail--
            Write-AppLog 'OK' "PID $processId confirmado encerrado na verificacao de termino."
        }
    }

    # Libera o rastreamento apenas apos a verificacao de término.
    $global:AiManagedPids.Clear()
    $global:AiManagedProcessMeta.Clear()
    $global:AiProcessTree.Clear()
    # Remove o registro persistente da sessao atual (ja encerrada).
    try {
        if (Test-Path -LiteralPath $script:AiRegisteredProcessesFile -PathType Leaf) {
            [System.IO.File]::Delete($script:AiRegisteredProcessesFile)
        }
    } catch {
        Write-AppLog 'WARN' "Nao foi possível remover o registro persistente apos a parada: $($_.Exception.Message)"
    }

    $failedList = if ($trueFailures.Count -gt 0) { ($trueFailures -join ', ') } else { 'nenhum' }
    Write-AppLog 'OK' "Parada concluída: $stoppedCount processo(s) encerrado(s); $($trueFailures.Count) falha(s). PIDs que não puderam ser encerrados: $failedList"
    return $stoppedCount
}

# ------------------------------------------------------------------------------
# CONTAGEM DE HERMES GERENCIADO PELA SESSAO ATUAL
# ------------------------------------------------------------------------------
# Retorna os processos Hermes (hermes.exe ou python.exe com headroom.cli wrap
# hermes) que pertencem à arvore da sessao atual do AmbienteIA. E' a unica
# fonte de verdade para o status RUNNING na interface: nunca usa varredura
# global de hermes.exe/python.exe do sistema.
function Get-ManagedHermesProcesses {
    $hermes = @()
    # Fonte de verdade: registro de metadados da sessao atual (nao varredura global do SO).
    foreach ($managedPid in @($global:AiManagedPids)) {
        # Valida propriedade da sessao atual antes de considerar o processo.
        if (-not (Test-ProcessBelongsToCurrentSession -ProcessId $managedPid)) { continue }
        try {
            $p = Get-Process -Id $managedPid -ErrorAction SilentlyContinue
            if ($null -eq $p) { continue }
            $name = $p.ProcessName
            $cmd  = [string]$p.CommandLine
            if ($name -eq 'hermes' -or ($name -like 'python*' -and $cmd -like '*headroom.cli*wrap*hermes*')) {
                $hermes += $p
            }
        } catch { }
    }
    return $hermes
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

        # Preparar variaveis de ambiente (credenciais do .env, HERMES_HOME, etc.)
        Set-AiEnvironmentVariables

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

        $hm = @(Get-ManagedHermesProcesses)
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