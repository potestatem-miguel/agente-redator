param(
  [int]$Port = 0
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

if ($Port -le 0) {
  $portFromEnv = [Environment]::GetEnvironmentVariable("PORT")
  if (-not [string]::IsNullOrWhiteSpace($portFromEnv)) {
    $Port = [int]$portFromEnv
  }
  else {
    $Port = 8080
  }
}

function Write-HttpJsonResponse {
  param(
    [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
    [Parameter(Mandatory = $true)]$Payload,
    [int]$StatusCode = 200
  )

  $json = $Payload | ConvertTo-Json -Depth 100
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $statusText = switch ($StatusCode) {
    200 { "OK" }
    202 { "Accepted" }
    400 { "Bad Request" }
    404 { "Not Found" }
    500 { "Internal Server Error" }
    default { "OK" }
  }
  $headers = @(
    "HTTP/1.1 $StatusCode $statusText",
    "Content-Type: application/json; charset=utf-8",
    "Content-Length: $($bodyBytes.Length)",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
  $Stream.Flush()
}

function Get-PowerShellExecutable {
  $pwsh = Get-Command "pwsh" -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) { return $pwsh.Source }

  $powershell = Get-Command "powershell" -ErrorAction SilentlyContinue
  if ($null -ne $powershell) { return $powershell.Source }

  throw "Nenhum executavel PowerShell encontrado. Instale pwsh ou powershell no ambiente."
}

function Convert-ToBoolean {
  param($Value)

  if ($Value -is [bool]) { return $Value }
  if ($null -eq $Value) { return $false }

  $text = ([string]$Value).Trim().ToLowerInvariant()
  switch ($text) {
    "true" { return $true }
    "1" { return $true }
    "yes" { return $true }
    "sim" { return $true }
    "false" { return $false }
    "0" { return $false }
    "no" { return $false }
    "nao" { return $false }
    "nÃ£o" { return $false }
    "" { return $false }
    default { throw "Valor invalido para stop_after_planning: '$Value'" }
  }
}

function Read-HttpRequest {
  param([Parameter(Mandatory = $true)][System.Net.Sockets.TcpClient]$Client)

  $stream = $Client.GetStream()
  $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 8192, $true)

  $requestLine = $reader.ReadLine()
  if ([string]::IsNullOrWhiteSpace($requestLine)) {
    throw "Request line vazia."
  }

  $requestParts = $requestLine.Split(' ')
  if ($requestParts.Length -lt 2) {
    throw "Request line invalida."
  }

  $headers = @{}
  while ($true) {
    $line = $reader.ReadLine()
    if ($line -eq $null -or $line -eq "") { break }
    $idx = $line.IndexOf(':')
    if ($idx -gt 0) {
      $key = $line.Substring(0, $idx).Trim().ToLowerInvariant()
      $value = $line.Substring($idx + 1).Trim()
      $headers[$key] = $value
    }
  }

  $body = ""
  if ($headers.ContainsKey("content-length")) {
    $length = [int]$headers["content-length"]
    if ($length -gt 0) {
      $buffer = New-Object char[] $length
      $read = 0
      while ($read -lt $length) {
        $count = $reader.Read($buffer, $read, $length - $read)
        if ($count -le 0) { break }
        $read += $count
      }
      $body = New-Object string ($buffer, 0, $read)
    }
  }

  return @{
    stream = $stream
    method = $requestParts[0].ToUpperInvariant()
    path = $requestParts[1]
    headers = $headers
    body = $body
  }
}

function Get-WorkspaceRoot {
  $workspaceRoot = $PSScriptRoot
  if ([string]::IsNullOrWhiteSpace($workspaceRoot)) {
    throw "Nao foi possivel resolver o diretorio raiz da aplicacao."
  }
  return $workspaceRoot
}

function Get-JobStoreRoot {
  $root = Join-Path (Get-WorkspaceRoot) "test-output\jobs"
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
  return ([guid]::NewGuid().ToString("N"))
}

function New-SafeTemaSlug {
  param([Parameter(Mandatory = $true)][string]$Tema)
  $safeTema = (($Tema -replace '[^a-zA-Z0-9_-]+', '-') -replace '-{2,}', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeTema)) { return "tema" }
  return $safeTema
}

function Get-OrchestratorScriptPath {
  return (Join-Path (Get-WorkspaceRoot) "agents\article-orchestrator\scripts\run_article_orchestrator.ps1")
}

function Get-OrchestratorOutputDir {
  param(
    [Parameter(Mandatory = $true)][string]$Tema,
    [Parameter(Mandatory = $true)][string]$JobId
  )

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $safeTema = New-SafeTemaSlug -Tema $Tema
  return (Join-Path (Get-WorkspaceRoot) ("test-output\api-{0}-{1}-{2}" -f $stamp, $safeTema, $JobId))
}

function Get-JobState {
  param([Parameter(Mandatory = $true)][string]$JobId)

  $jobDir = Get-JobDirectory -JobId $JobId
  if (-not (Test-Path $jobDir)) {
    throw "Job nao encontrado."
  }

  $donePath = Join-Path $jobDir "done.json"
  if (Test-Path $donePath) { return (Read-JsonFile -Path $donePath) }

  $errorPath = Join-Path $jobDir "error.json"
  if (Test-Path $errorPath) { return (Read-JsonFile -Path $errorPath) }

  $runningPath = Join-Path $jobDir "running.json"
  if (Test-Path $runningPath) { return (Read-JsonFile -Path $runningPath) }

  $queuedPath = Join-Path $jobDir "queued.json"
  if (Test-Path $queuedPath) { return (Read-JsonFile -Path $queuedPath) }

  throw "Estado do job nao encontrado."
}

function Start-OrchestratorJob {
  param(
    [Parameter(Mandatory = $true)][string]$Tema,
    [bool]$StopAfterPlanning = $false
  )

  $jobId = New-JobId
  $jobDir = Get-JobDirectory -JobId $jobId
  $outputDir = Get-OrchestratorOutputDir -Tema $Tema -JobId $jobId
  $queuedPath = Join-Path $jobDir "queued.json"
  $workerScriptPath = Join-Path $jobDir "worker.ps1"
  $orchestratorScript = Get-OrchestratorScriptPath
  $powerShellExe = Get-PowerShellExecutable

  New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
  Write-JsonFile -Path $queuedPath -Payload @{
    ok = $true
    status = "queued"
    job_id = $jobId
    tema = $Tema
    stop_after_planning = $StopAfterPlanning
    output_dir = $outputDir
    created_at = (Get-Date).ToString("s")
  }

  $temaEscaped = $Tema.Replace("'", "''")
  $jobDirEscaped = $jobDir.Replace("'", "''")
  $outputDirEscaped = $outputDir.Replace("'", "''")
  $orchestratorEscaped = $orchestratorScript.Replace("'", "''")
  $powerShellEscaped = $powerShellExe.Replace("'", "''")
  $stopAsText = if ($StopAfterPlanning) { "True" } else { "False" }

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
"@

  $workerContent += @"

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
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $workerScriptPath
  ) -WorkingDirectory (Get-WorkspaceRoot) | Out-Null

  return @{
    ok = $true
    status = "queued"
    job_id = $jobId
    tema = $Tema
    stop_after_planning = $StopAfterPlanning
    output_dir = $outputDir
  }
}

function Get-QueryParameters {
  param([Parameter(Mandatory = $true)][string]$Path)

  $parts = $Path.Split('?', 2)
  $route = $parts[0]
  $query = @{}

  if ($parts.Length -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
    foreach ($pair in $parts[1].Split('&')) {
      if ([string]::IsNullOrWhiteSpace($pair)) { continue }
      $kv = $pair.Split('=', 2)
      $key = [System.Uri]::UnescapeDataString($kv[0])
      $value = if ($kv.Length -gt 1) { [System.Uri]::UnescapeDataString($kv[1]) } else { "" }
      $query[$key] = $value
    }
  }

  return @{
    route = $route
    query = $query
  }
}

$listener = [System.Net.Sockets.TcpListener]::Create($Port)
$listener.Start()

Write-Host ("API pronta em http://0.0.0.0:{0}" -f $Port)

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()

    try {
      $request = Read-HttpRequest -Client $client
      $pathInfo = Get-QueryParameters -Path $request.path
      $route = $pathInfo.route
      $query = $pathInfo.query

      if ($request.method -eq "GET" -and $route -eq "/health") {
        Write-HttpJsonResponse -Stream $request.stream -StatusCode 200 -Payload @{
          ok = $true
          service = "article-orchestrator"
          timestamp = (Get-Date).ToString("s")
        }
        continue
      }

      if ($request.method -eq "POST" -and $route -eq "/run-article") {
        $bodyText = [string]$request.body
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
          throw "Body JSON obrigatorio."
        }

        $body = $bodyText | ConvertFrom-Json
        $tema = [string]$body.tema
        $stopAfterPlanning = Convert-ToBoolean -Value $body.stop_after_planning

        if ([string]::IsNullOrWhiteSpace($tema)) {
          throw "Campo 'tema' obrigatorio."
        }

        $job = Start-OrchestratorJob -Tema $tema -StopAfterPlanning:$stopAfterPlanning
        Write-HttpJsonResponse -Stream $request.stream -StatusCode 202 -Payload $job
        continue
      }

      if ($request.method -eq "GET" -and $route -eq "/job-status") {
        $jobId = [string]$query["id"]
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
        if ($state.PSObject.Properties.Name -contains "error") {
          $payload.error = $state.error
        }
        Write-HttpJsonResponse -Stream $request.stream -StatusCode 200 -Payload $payload
        continue
      }

      if ($request.method -eq "GET" -and $route -eq "/job-result") {
        $jobId = [string]$query["id"]
        if ([string]::IsNullOrWhiteSpace($jobId)) {
          throw "Query param 'id' obrigatorio."
        }

        $state = Get-JobState -JobId $jobId
        if ($state.status -eq "completed") {
          Write-HttpJsonResponse -Stream $request.stream -StatusCode 200 -Payload $state.payload
          continue
        }

        if ($state.status -eq "failed") {
          Write-HttpJsonResponse -Stream $request.stream -StatusCode 500 -Payload @{
            ok = $false
            status = "failed"
            job_id = $state.job_id
            error = $state.error
          }
          continue
        }

        Write-HttpJsonResponse -Stream $request.stream -StatusCode 200 -Payload @{
          ok = $true
          status = $state.status
          job_id = $state.job_id
          message = "Job ainda em execucao."
        }
        continue
      }

      Write-HttpJsonResponse -Stream $request.stream -StatusCode 404 -Payload @{
        ok = $false
        error = "Rota nao encontrada."
      }
    }
    catch {
      try {
        $stream = if ($null -ne $request -and $null -ne $request.stream) { $request.stream } else { $client.GetStream() }
        Write-HttpJsonResponse -Stream $stream -StatusCode 500 -Payload @{
          ok = $false
          error = $_.Exception.Message
        }
      }
      catch {
      }
    }
    finally {
      if ($null -ne $client) {
        $client.Close()
      }
    }
  }
}
finally {
  $listener.Stop()
}
