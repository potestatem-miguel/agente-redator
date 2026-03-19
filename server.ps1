param(
  [int]$Port = 8080
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

function Write-HttpJsonResponse {
  param(
    [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
    [Parameter(Mandatory = $true)]$Payload,
    [int]$StatusCode = 200
  )

  $json = $Payload | ConvertTo-Json -Depth 50
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $statusText = switch ($StatusCode) {
    200 { "OK" }
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

function Invoke-OrchestratorRun {
  param(
    [Parameter(Mandatory = $true)][string]$Tema,
    [bool]$StopAfterPlanning = $false
  )

  $workspaceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
  $orchestratorScript = Join-Path $workspaceRoot "agents\article-orchestrator\scripts\run_article_orchestrator.ps1"
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $safeTema = (($Tema -replace '[^a-zA-Z0-9_-]+', '-') -replace '-{2,}', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($safeTema)) { $safeTema = "tema" }
  $outputDir = Join-Path $workspaceRoot ("test-output\api-{0}-{1}" -f $stamp, $safeTema)

  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $orchestratorScript,
    "-Tema", $Tema,
    "-OutputDir", $outputDir
  )
  if ($StopAfterPlanning) {
    $args += "-StopAfterPlanning"
  }

  $powerShellExe = Get-PowerShellExecutable
  $raw = & $powerShellExe @args 2>&1
  $text = (($raw | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()

  if ($LASTEXITCODE -ne 0) {
    throw "Falha ao executar o article-orchestrator. Saida: $text"
  }

  $publishPackagePath = Join-Path $outputDir "13-publish-package.json"
  $planningPath = Join-Path $outputDir "06-article-plan.json"

  if (-not $StopAfterPlanning -and (Test-Path $publishPackagePath)) {
    return @{
      mode = "full"
      output_dir = $outputDir
      result = (Get-Content -Raw -Encoding UTF8 $publishPackagePath | ConvertFrom-Json)
    }
  }

  if ($StopAfterPlanning -and (Test-Path $planningPath)) {
    return @{
      mode = "planning"
      output_dir = $outputDir
      research_pack = (Get-Content -Raw -Encoding UTF8 (Join-Path $outputDir "01-research-pack.json") | ConvertFrom-Json)
      topic_validation = (Get-Content -Raw -Encoding UTF8 (Join-Path $outputDir "02-topic-validation.json") | ConvertFrom-Json)
      approved_topic = (Get-Content -Raw -Encoding UTF8 (Join-Path $outputDir "03-approved-topic.json") | ConvertFrom-Json)
      duplicate_check = (Get-Content -Raw -Encoding UTF8 (Join-Path $outputDir "04-duplicate-check.json") | ConvertFrom-Json)
      course_match = (Get-Content -Raw -Encoding UTF8 (Join-Path $outputDir "05-course-match.json") | ConvertFrom-Json)
      article_plan = (Get-Content -Raw -Encoding UTF8 $planningPath | ConvertFrom-Json)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($text)) {
    try {
      return @{
        mode = if ($StopAfterPlanning) { "planning" } else { "full" }
        output_dir = $outputDir
        result = ($text | ConvertFrom-Json)
      }
    }
    catch {
    }
  }

  throw "Execucao concluida sem artefato esperado. Output dir: $outputDir"
}

$listener = [System.Net.Sockets.TcpListener]::Create($Port)
$listener.Start()

Write-Host ("API pronta em http://0.0.0.0:{0}" -f $Port)

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()

    try {
      $request = Read-HttpRequest -Client $client

      if ($request.method -eq "GET" -and $request.path -eq "/health") {
        Write-HttpJsonResponse -Stream $request.stream -StatusCode 200 -Payload @{
          ok = $true
          service = "article-orchestrator"
          timestamp = (Get-Date).ToString("s")
        }
        continue
      }

      if ($request.method -eq "POST" -and $request.path -eq "/run-article") {
        $bodyText = [string]$request.body
        if ([string]::IsNullOrWhiteSpace($bodyText)) {
          throw "Body JSON obrigatorio."
        }

        $body = $bodyText | ConvertFrom-Json
        $tema = [string]$body.tema
        $stopAfterPlanning = [bool]$body.stop_after_planning

        if ([string]::IsNullOrWhiteSpace($tema)) {
          throw "Campo 'tema' obrigatorio."
        }

        $result = Invoke-OrchestratorRun -Tema $tema -StopAfterPlanning:$stopAfterPlanning
        Write-HttpJsonResponse -Stream $request.stream -StatusCode 200 -Payload $result
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
