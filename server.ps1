param(
  [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

if ($Port -le 0) {
  $portFromEnv = [Environment]::GetEnvironmentVariable('PORT')
  if (-not [string]::IsNullOrWhiteSpace($portFromEnv)) {
    $Port = [int]$portFromEnv
  }
  else {
    $Port = 8080
  }
}

function Get-PowerShellExecutable {
  $pwsh = Get-Command 'pwsh' -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) { return $pwsh.Source }

  $powershell = Get-Command 'powershell' -ErrorAction SilentlyContinue
  if ($null -ne $powershell) { return $powershell.Source }

  throw 'Nenhum executavel PowerShell encontrado. Instale pwsh ou powershell no ambiente.'
}

function Convert-ToBoolean {
  param($Value)

  if ($Value -is [bool]) { return $Value }
  if ($null -eq $Value) { return $false }

  $text = ([string]$Value).Trim().ToLowerInvariant()
  switch ($text) {
    'true' { return $true }
    '1' { return $true }
    'yes' { return $true }
    'sim' { return $true }
    'false' { return $false }
    '0' { return $false }
    'no' { return $false }
    'nao' { return $false }
    'não' { return $false }
    '' { return $false }
    default { throw "Valor invalido para stop_after_planning: '$Value'" }
  }
}

function Write-HttpJsonResponse {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)]$Payload,
    [int]$StatusCode = 200
  )

  $json = $Payload | ConvertTo-Json -Depth 100
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = 'application/json; charset=utf-8'
  $Response.ContentEncoding = [System.Text.Encoding]::UTF8
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $Response.OutputStream.Flush()
  $Response.Close()
}

function Get-WorkspaceRoot {
  $workspaceRoot = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($workspaceRoot)) {
    throw 'Nao foi possivel resolver o diretorio raiz da aplicacao.'
  }
  return $workspaceRoot
}

function Get-JobStoreRoot {
  $root = Join-Path (Get-WorkspaceRoot) 'test-output/jobs'
  if (-not (Test-Path $root)) {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
  }
  return $root
}

function Get-JobDirectory {
  param([Parameter(Mandatory = $true)][string]$JobId)
  return (Join-Path (Get-JobStoreRoot) $JobId)
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Payload
  )

  $dir = Split-Path -Parent $Path
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  ($Payload | ConvertTo-Json -Depth 100) | Set-Content -Path $Path -Encoding UTF8
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json)
}

function New-JobId {
  return ([guid]::NewGuid().ToString('N'))
}

function New-SafeTemaSlug {
  param([Parameter(Mandatory = $true)][string]$Tema)
  $safeTema = (($Tema -replace '[^a-zA-Z0-9_-]+', '-') -replace '-{2,}', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeTema)) { return 'tema' }
  return $safeTema
}

function Get-OrchestratorScriptPath {
  return (Join-Path (Get-WorkspaceRoot) 'agents/article-orchestrator/scripts/run_article_orchestrator.ps1')
}

function Get-OrchestratorOutputDir {
  param(
    [Parameter(Mandatory = $true)][string]$Tema,
    [Parameter(Mandatory = $true)][string]$JobId
  )

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $safeTema = New-SafeTemaSlug -Tema $Tema
  return (Join-Path (Get-WorkspaceRoot) ("test-output/api-{0}-{1}-{2}" -f $stamp, $safeTema, $JobId))
}

function Get-JobState {
  param([Parameter(Mandatory = $true)][string]$JobId)

  $jobDir = Get-JobDirectory -JobId $JobId
  if (-not (Test-Path $jobDir)) {
    throw 'Job nao encontrado.'
  }

  foreach ($name in @('done.json', 'error.json', 'running.json', 'queued.json')) {
    $path = Join-Path $jobDir $name
    if (Test-Path $path) {
      return (Read-JsonFile -Path $path)
    }
  }

  throw 'Estado do job nao encontrado.'
}

function Start-OrchestratorJob {
  param(
    [Parameter(Mandatory = $true)][string]$Tema,
    [bool]$StopAfterPlanning = $false
  )

  $jobId = New-JobId
  $jobDir = Get-JobDirectory -JobId $jobId
  $outputDir = Get-OrchestratorOutputDir -Tema $Tema -JobId $jobId
  $queuedPath = Join-Path $jobDir 'queued.json'
  $workerScriptPath = Join-Path $jobDir 'worker.ps1'
  $orchestratorScript = Get-OrchestratorScriptPath
  $powerShellExe = Get-PowerShellExecutable

  New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
  Write-JsonFile -Path $queuedPath -Payload @{
    ok = $true
    status = 'queued'
    job_id = $jobId
    tema = $Tema
    stop_after_planning = $StopAfterPlanning
    output_dir = $outputDir
    created_at = (Get-Date).ToString('s')
  }

  $temaEscaped = $Tema.Replace("'", "''")
  $jobDirEscaped = $jobDir.Replace("'", "''")
  $outputDirEscaped = $outputDir.Replace("'", "''")
  $orchestratorEscaped = $orchestratorScript.Replace("'", "''")
  $powerShellEscaped = $powerShellExe.Replace("'", "''")
  $stopAsText = if ($StopAfterPlanning) { 'True' } else { 'False' }

  $workerContent = @"
`$ErrorActionPreference = 'Stop'
`$Utf8NoBom = New-Object System.Text.UTF8Encoding(`$false)
[Console]::InputEncoding = `$Utf8NoBom
[Console]::OutputEncoding = `$Utf8NoBom
`$OutputEncoding = `$Utf8NoBom

function Write-JobJson {
  param([string]`$Path, `$Payload)
  (`$Payload | ConvertTo-Json -Depth 100) | Set-Content -Path `$Path -Encoding UTF8
}

`$jobDir = '$jobDirEscaped'
`$runningPath = Join-Path `$jobDir 'running.json'
`$donePath = Join-Path `$jobDir 'done.json'
`$errorPath = Join-Path `$jobDir 'error.json'
`$logPath = Join-Path `$jobDir 'worker.log'
`$outputDir = '$outputDirEscaped'
`$tema = '$temaEscaped'
`$stopAfterPlanning = [System.Convert]::ToBoolean('$stopAsText')

try {
  Write-JobJson -Path `$runningPath -Payload @{
    ok = `$true
    status = 'running'
    job_id = '$jobId'
    tema = `$tema
    stop_after_planning = `$stopAfterPlanning
    output_dir = `$outputDir
    started_at = (Get-Date).ToString('s')
  }

  `$args = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', '$orchestratorEscaped',
    '-Tema', `$tema,
    '-OutputDir', `$outputDir
  )

  if (`$stopAfterPlanning) {
    `$args += '-StopAfterPlanning'
  }

  `$raw = & '$powerShellEscaped' @args 2>&1
  `$text = ((`$raw | ForEach-Object { `$_.ToString() }) -join [Environment]::NewLine).Trim()
  if (`$text) {
    `$text | Set-Content -Path `$logPath -Encoding UTF8
  }

  if (`$LASTEXITCODE -ne 0) {
    throw "Falha ao executar o article-orchestrator. Saida: `$text"
  }

  if (`$stopAfterPlanning) {
    `$payload = @{
      mode = 'planning'
      output_dir = `$outputDir
      research_pack = (Get-Content -Raw -Encoding UTF8 (Join-Path `$outputDir '01-research-pack.json') | ConvertFrom-Json)
      topic_validation = (Get-Content -Raw -Encoding UTF8 (Join-Path `$outputDir '02-topic-validation.json') | ConvertFrom-Json)
      approved_topic = (Get-Content -Raw -Encoding UTF8 (Join-Path `$outputDir '03-approved-topic.json') | ConvertFrom-Json)
      duplicate_check = (Get-Content -Raw -Encoding UTF8 (Join-Path `$outputDir '04-duplicate-check.json') | ConvertFrom-Json)
      course_match = (Get-Content -Raw -Encoding UTF8 (Join-Path `$outputDir '05-course-match.json') | ConvertFrom-Json)
      article_plan = (Get-Content -Raw -Encoding UTF8 (Join-Path `$outputDir '06-article-plan.json') | ConvertFrom-Json)
    }
  }
  else {
    `$payload = @{
      mode = 'full'
      output_dir = `$outputDir
      result = (Get-Content -Raw -Encoding UTF8 (Join-Path `$outputDir '13-publish-package.json') | ConvertFrom-Json)
    }
  }

  Write-JobJson -Path `$donePath -Payload @{
    ok = `$true
    status = 'completed'
    job_id = '$jobId'
    tema = `$tema
    stop_after_planning = `$stopAfterPlanning
    output_dir = `$outputDir
    completed_at = (Get-Date).ToString('s')
    payload = `$payload
  }
}
catch {
  Write-JobJson -Path `$errorPath -Payload @{
    ok = `$false
    status = 'failed'
    job_id = '$jobId'
    tema = `$tema
    stop_after_planning = `$stopAfterPlanning
    output_dir = `$outputDir
    failed_at = (Get-Date).ToString('s')
    error = `$_.Exception.Message
  }
  exit 1
}
"@

  Set-Content -Path $workerScriptPath -Value $workerContent -Encoding UTF8

  Start-Process -FilePath $powerShellExe -ArgumentList @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $workerScriptPath
  ) -WorkingDirectory (Get-WorkspaceRoot) | Out-Null

  return @{
    ok = $true
    status = 'queued'
    job_id = $jobId
    tema = $Tema
    stop_after_planning = $StopAfterPlanning
    output_dir = $outputDir
  }
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://*:$Port/")
$listener.Start()

Write-Host ("API pronta em http://0.0.0.0:{0}" -f $Port)

try {
  while ($true) {
    $context = $listener.GetContext()
    try {
      $request = $context.Request
      $response = $context.Response
      $route = $request.Url.AbsolutePath

      Write-Host ((Get-Date).ToString('s') + ' ' + $request.HttpMethod + ' ' + $route)

      if ($request.HttpMethod -eq 'GET' -and $route -eq '/health') {
        Write-HttpJsonResponse -Response $response -StatusCode 200 -Payload @{
          ok = $true
          service = 'article-orchestrator'
          timestamp = (Get-Date).ToString('s')
        }
        continue
      }

      if ($request.HttpMethod -eq 'POST' -and $route -eq '/run-article') {
        $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
        $bodyText = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
          throw 'Body JSON obrigatorio.'
        }

        $body = $bodyText | ConvertFrom-Json
        $tema = [string]$body.tema
        $stopAfterPlanning = Convert-ToBoolean -Value $body.stop_after_planning

        if ([string]::IsNullOrWhiteSpace($tema)) {
          throw "Campo 'tema' obrigatorio."
        }

        $job = Start-OrchestratorJob -Tema $tema -StopAfterPlanning:$stopAfterPlanning
        Write-HttpJsonResponse -Response $response -StatusCode 202 -Payload $job
        continue
      }

      if ($request.HttpMethod -eq 'GET' -and $route -eq '/job-status') {
        $jobId = [string]$request.QueryString['id']
        if ([string]::IsNullOrWhiteSpace($jobId)) {
          throw "Query param 'id' obrigatorio."
        }

        $state = Get-JobState -JobId $jobId
        $payload = @{
          ok = $state.ok
          status = $state.status
          job_id = $state.job_id
          tema = $state.tema
          stop_after_planning = $state.stop_after_planning
          output_dir = $state.output_dir
        }
        if ($state.PSObject.Properties.Name -contains 'error') {
          $payload.error = $state.error
        }
        Write-HttpJsonResponse -Response $response -StatusCode 200 -Payload $payload
        continue
      }

      if ($request.HttpMethod -eq 'GET' -and $route -eq '/job-result') {
        $jobId = [string]$request.QueryString['id']
        if ([string]::IsNullOrWhiteSpace($jobId)) {
          throw "Query param 'id' obrigatorio."
        }

        $state = Get-JobState -JobId $jobId
        if ($state.status -eq 'completed') {
          Write-HttpJsonResponse -Response $response -StatusCode 200 -Payload $state.payload
          continue
        }

        if ($state.status -eq 'failed') {
          Write-HttpJsonResponse -Response $response -StatusCode 500 -Payload @{
            ok = $false
            status = 'failed'
            job_id = $state.job_id
            error = $state.error
          }
          continue
        }

        Write-HttpJsonResponse -Response $response -StatusCode 200 -Payload @{
          ok = $true
          status = $state.status
          job_id = $state.job_id
          message = 'Job ainda em execucao.'
        }
        continue
      }

      Write-HttpJsonResponse -Response $response -StatusCode 404 -Payload @{
        ok = $false
        error = 'Rota nao encontrada.'
      }
    }
    catch {
      try {
        Write-Host ('ERRO ' + $_.Exception.Message)
        Write-HttpJsonResponse -Response $context.Response -StatusCode 500 -Payload @{
          ok = $false
          error = $_.Exception.Message
        }
      }
      catch {
      }
    }
  }
}
finally {
  $listener.Stop()
}
