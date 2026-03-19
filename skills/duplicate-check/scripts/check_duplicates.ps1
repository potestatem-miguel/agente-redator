param(
  [Parameter(Mandatory = $true)]
  [string]$Title,

  [Parameter(Mandatory = $true)]
  [string]$Slug,

  [string]$Keyword = "",

  [double]$MinRelated = 0.65,

  [double]$MinDuplicate = 0.80,

  [int]$Limit = 5,

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
    throw "Falha ao gerar embedding do titulo."
  }

  return $response.data[0].embedding
}

function Normalize-ExactMatch {
  param([object]$Rows, [string]$Slug)

  $allRows = @()
  if ($Rows -is [System.Array]) { $allRows = $Rows }
  elseif ($null -ne $Rows) { $allRows = @($Rows) }

  foreach ($row in $allRows) {
    if ($null -ne $row.slug -or $null -ne $row.found) {
      return @{
        slug  = [string]$row.slug
        found = [bool]$row.found
      }
    }
  }

  return @{
    slug  = $Slug
    found = $false
  }
}

function Normalize-TopK {
  param([object]$Rows)

  $list = @()
  if ($Rows -is [System.Array]) { $list = $Rows }
  elseif ($null -ne $Rows) { $list = @($Rows) }

  $out = @()
  foreach ($row in $list) {
    $out += @{
      wp_id = if ($null -ne $row.wp_id) { [int]$row.wp_id } else { $null }
      title = if ($null -ne $row.title) { [string]$row.title } else { $null }
      score = if ($null -ne $row.score) { [double]$row.score } else { $null }
    }
  }
  return $out
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
  $exactRows = Invoke-JsonPost `
    -Url ($supabaseUrl.TrimEnd("/") + "/rest/v1/rpc/check_slugs") `
    -Headers $supabaseHeaders `
    -Body @{ slugs = @($Slug) }

  $exactMatch = Normalize-ExactMatch -Rows $exactRows -Slug $Slug

  if ($exactMatch.found) {
    @{
      status = "duplicate_exact"
      exact_match = $exactMatch
      semantic_match = $null
      recommended_action = "discard_or_change_slug"
      alternative_angle = $null
      top_k = @()
      debug = @{
        title = $Title
        slug = $Slug
        keyword = $Keyword
        min_related = $MinRelated
        min_duplicate = $MinDuplicate
      }
      error = $null
    } | ConvertTo-Json -Depth 20
    exit 0
  }

  $embedding = New-OpenAIEmbedding -ApiKey $openAiKey -InputText $Title

  $semanticRows = Invoke-JsonPost `
    -Url ($supabaseUrl.TrimEnd("/") + "/rest/v1/rpc/find_similar_titles") `
    -Headers $supabaseHeaders `
    -Body @{
      _embedding = @($embedding)
      _limit = $Limit
      _min_score = 0
    }

  $topK = Normalize-TopK -Rows $semanticRows
  $semanticMatch = if ($topK.Count -gt 0) { $topK[0] } else { $null }
  $topScore = if ($semanticMatch -and $null -ne $semanticMatch.score) { [double]$semanticMatch.score } else { 0.0 }

  $status = "unique"
  $recommendedAction = "proceed"
  $alternativeAngle = $null

  if ($topScore -ge $MinDuplicate) {
    $status = "duplicate_semantic"
    $recommendedAction = "discard_or_reframe"
    $alternativeAngle = "Reenquadrar o tema para um recorte mais especifico, evitando o mesmo nucleo do titulo existente."
  }
  elseif ($topScore -ge $MinRelated) {
    $status = "related"
    $recommendedAction = "refine_angle"
    $alternativeAngle = "Manter o assunto, mas mudar a promessa central, o publico ou o recorte pratico do artigo."
  }

  $jsonOut = @{
    status = $status
    exact_match = $exactMatch
    semantic_match = $semanticMatch
    recommended_action = $recommendedAction
    alternative_angle = $alternativeAngle
    top_k = $topK
    debug = @{
      title = $Title
      slug = $Slug
      keyword = $Keyword
      min_related = $MinRelated
      min_duplicate = $MinDuplicate
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
    status = "related"
    exact_match = $null
    semantic_match = $null
    recommended_action = "retry_check"
    alternative_angle = $null
    top_k = @()
    debug = @{
      title = $Title
      slug = $Slug
      keyword = $Keyword
      min_related = $MinRelated
      min_duplicate = $MinDuplicate
    }
    error = $_.Exception.Message
  } | ConvertTo-Json -Depth 20
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Set-Content -Path $OutputPath -Value $jsonOut -Encoding UTF8
  }
  $jsonOut
  exit 1
}
