param(
  [string]$Keyword = "",
  [string]$Title = "",
  [int]$Limit = 5,
  [int]$FinalCount = 2,
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

function Get-RequiredEnv([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Variavel de ambiente obrigatoria ausente: $Name"
  }
  return $value
}

function Invoke-JsonPost {
  param(
    [string]$Url,
    [hashtable]$Headers,
    [object]$Body
  )

  $json = $Body | ConvertTo-Json -Depth 20 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  return Invoke-RestMethod -Method Post -Uri $Url -Headers $Headers -Body $bytes -ContentType "application/json; charset=utf-8"
}

function New-OpenAIEmbedding {
  param(
    [string]$ApiKey,
    [string]$InputText
  )

  $headers = @{
    "Authorization" = "Bearer $ApiKey"
    "Content-Type"  = "application/json"
  }

  $body = @{
    model = "text-embedding-3-small"
    input = $InputText
  }

  $response = Invoke-JsonPost -Url "https://api.openai.com/v1/embeddings" -Headers $headers -Body $body
  if (-not $response.data -or -not $response.data[0].embedding) {
    throw "Falha ao gerar embedding da consulta."
  }

  return $response.data[0].embedding
}

function Normalize-Rows {
  param([object]$Rows)

  $list = @()
  if ($Rows -is [System.Array]) { $list = $Rows }
  elseif ($null -ne $Rows) { $list = @($Rows) }

  $map = @{}
  foreach ($row in $list) {
    $key = ""
    if ($null -ne $row.slug -and -not [string]::IsNullOrWhiteSpace([string]$row.slug)) { $key = [string]$row.slug }
    elseif ($null -ne $row.id) { $key = [string]$row.id }
    elseif ($null -ne $row.link -and -not [string]::IsNullOrWhiteSpace([string]$row.link)) { $key = [string]$row.link }
    else { $key = [guid]::NewGuid().ToString() }

    $item = @{
      id = if ($null -ne $row.id) { [int]$row.id } else { $null }
      slug = if ($null -ne $row.slug) { [string]$row.slug } else { $null }
      title = if ($null -ne $row.title) { [string]$row.title } else { $null }
      url = if ($null -ne $row.link) { [string]$row.link } else { $null }
      score = if ($null -ne $row.score) { [double]$row.score } else { $null }
    }

    $itemScore = if ($null -ne $item.score) { [double]$item.score } else { -1 }
    $existingScore = if ($map.ContainsKey($key) -and $null -ne $map[$key].score) { [double]$map[$key].score } else { -1 }
    if (-not $map.ContainsKey($key) -or ($itemScore -gt $existingScore)) {
      $map[$key] = $item
    }
  }

  $values = @($map.Values)
  $values = $values | Sort-Object -Property @{ Expression = { if ($null -ne $_.score) { $_.score } else { -1 } } } -Descending
  return $values
}

function Build-Anchor {
  param([object]$Course, [string]$KeywordText)

  if (-not [string]::IsNullOrWhiteSpace($KeywordText)) {
    return "curso de $KeywordText"
  }
  if ($Course.title) {
    return $Course.title
  }
  return $null
}

$queryText = if (-not [string]::IsNullOrWhiteSpace($Keyword)) { $Keyword } else { $Title }
if ([string]::IsNullOrWhiteSpace($queryText)) {
  throw "Informe Keyword ou Title para consultar cursos."
}

$supabaseUrl = Get-RequiredEnv "SUPABASE_URL"
$supabaseKey = Get-RequiredEnv "SUPABASE_ANON_KEY"
$openAiKey = Get-RequiredEnv "OPENAI_API_KEY"

$supabaseHeaders = @{
  "apikey"        = $supabaseKey
  "Authorization" = "Bearer $supabaseKey"
  "Content-Type"  = "application/json"
  "Accept"        = "application/json"
}

try {
  $embedding = New-OpenAIEmbedding -ApiKey $openAiKey -InputText $queryText

  $rows = Invoke-JsonPost `
    -Url ($supabaseUrl.TrimEnd("/") + "/rest/v1/rpc/match_cursos") `
    -Headers $supabaseHeaders `
    -Body @{
      query_embedding = @($embedding)
    }

  $ranked = Normalize-Rows -Rows $rows
  $selected = @($ranked | Select-Object -First $FinalCount)

  $courses = @()
  foreach ($course in $selected) {
    if ([string]::IsNullOrWhiteSpace($course.url)) { continue }
    $courses += @{
      id = $course.id
      slug = $course.slug
      title = $course.title
      url = $course.url
      anchor = Build-Anchor -Course $course -KeywordText $Keyword
      reason = "Curso semanticamente proximo ao tema consultado."
      score = $course.score
    }
  }

  $jsonOut = @{
    courses = $courses
    internal_links = @()
    debug = @{
      query_text = $queryText
      limit = $Limit
    }
    error = $null
  } | ConvertTo-Json -Depth 20
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Set-Content -Path $OutputPath -Value $jsonOut -Encoding UTF8
  }
  $jsonOut
}
catch {
  $jsonOut = @{
    courses = @()
    internal_links = @()
    debug = @{
      query_text = $queryText
      limit = $Limit
    }
    error = $_.Exception.Message
  } | ConvertTo-Json -Depth 20
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Set-Content -Path $OutputPath -Value $jsonOut -Encoding UTF8
  }
  $jsonOut
  exit 1
}
