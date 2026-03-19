param(
  [Parameter(Mandatory = $true)]
  [string]$Tema,

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

function Invoke-SerpApiGet {
  param(
    [hashtable]$Query
  )

  $apiKey = Get-RequiredEnv "SERPAPI_API_KEY"
  $pairs = @()
  foreach ($key in $Query.Keys) {
    $value = [string]$Query[$key]
    $pairs += ("{0}={1}" -f [System.Uri]::EscapeDataString($key), [System.Uri]::EscapeDataString($value))
  }
  $pairs += ("api_key={0}" -f [System.Uri]::EscapeDataString($apiKey))
  $uri = "https://serpapi.com/search.json?" + ($pairs -join "&")
  return Invoke-RestMethod -Method Get -Uri $uri
}

function Build-ResearchPack {
  param(
    [string]$Tema,
    [object]$Search,
    [object]$Trends,
    [string[]]$MissingSources
  )

  $candidateQueries = @()
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'

  if ($null -ne $Search.search_parameters.q) {
    $seed = [string]$Search.search_parameters.q
    [void]$seen.Add($seed)
    $candidateQueries += @{
      query = $seed
      intent = "informacional"
      source = "google"
    }
  }

  foreach ($item in @($Search.related_searches)) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.query)) { continue }
    $query = [string]$item.query
    if ($seen.Add($query)) {
      $candidateQueries += @{
        query = $query
        intent = "informacional"
        source = "related_searches"
      }
    }
  }

  foreach ($bucket in @("rising", "top")) {
    if ($null -eq $Trends -or $null -eq $Trends.related_queries.$bucket) { continue }
    foreach ($item in @($Trends.related_queries.$bucket)) {
      if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.query)) { continue }
      $query = [string]$item.query
      if ($seen.Add($query)) {
        $candidateQueries += @{
          query = $query
          intent = "informacional"
          source = "google_trends"
        }
      }
    }
  }

  $paa = @()
  foreach ($item in @($Search.related_questions)) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.question)) { continue }
    $snippet = $null
    foreach ($block in @($item.text_blocks)) {
      if ($null -ne $block -and $block.type -eq "paragraph" -and -not [string]::IsNullOrWhiteSpace([string]$block.snippet)) {
        $snippet = [string]$block.snippet
        break
      }
    }
    $paa += @{
      question = [string]$item.question
      snippet = $snippet
    }
  }

  $organic = @()
  foreach ($item in @($Search.organic_results)) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.title)) { continue }
    $organic += @{
      title = [string]$item.title
      snippet = if ([string]::IsNullOrWhiteSpace([string]$item.snippet)) { $null } else { [string]$item.snippet }
      url = if ([string]::IsNullOrWhiteSpace([string]$item.link)) { $null } else { [string]$item.link }
    }
  }

  $relatedSearches = @()
  foreach ($item in @($Search.related_searches)) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.query)) { continue }
    $relatedSearches += [string]$item.query
  }

  foreach ($bucket in @("rising", "top")) {
    if ($null -eq $Trends -or $null -eq $Trends.related_queries.$bucket) { continue }
    foreach ($item in @($Trends.related_queries.$bucket)) {
      if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.query)) { continue }
      $query = [string]$item.query
      if ($relatedSearches -notcontains $query) {
        $relatedSearches += $query
      }
    }
  }

  return @{
    status = if ($MissingSources.Count -eq 0) { "ok" } else { "partial" }
    tema = $Tema
    seed_keyword = if ($null -ne $Search.search_parameters.q) { [string]$Search.search_parameters.q } else { $Tema }
    candidate_queries = $candidateQueries
    people_also_ask = $paa
    related_searches = $relatedSearches
    organic_highlights = $organic
    search_intent_summary = "Consulta informacional baseada em sinais reais de Google Search, People Also Ask, related searches e Google Trends."
    snippet_opportunities = @("lista", "faq", "passo a passo")
    ambiguidades = @()
    missing_sources = $MissingSources
  }
}

try {
  $jsonOut = $null
  $search = Invoke-SerpApiGet -Query @{
    engine = "google"
    q = $Tema
    gl = "br"
    hl = "pt-br"
    google_domain = "google.com.br"
  }

  $trends = $null
  $missingSources = @()
  try {
    $trends = Invoke-SerpApiGet -Query @{
      engine = "google_trends"
      q = $Tema
      geo = "BR"
      hl = "pt-br"
      data_type = "RELATED_QUERIES"
      date = "today 1-m"
    }
  }
  catch {
    $trends = $null
    $missingSources += "google_trends_related_queries"
  }

  $jsonOut = Build-ResearchPack -Tema $Tema -Search $search -Trends $trends -MissingSources $missingSources | ConvertTo-Json -Depth 30
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Set-Content -Path $OutputPath -Value $jsonOut -Encoding UTF8
  }
  $jsonOut
}
catch {
  $jsonOut = @{
    status = "needs_clarification"
    tema = $Tema
    seed_keyword = $Tema
    candidate_queries = @()
    people_also_ask = @()
    related_searches = @()
    organic_highlights = @()
    search_intent_summary = ""
    snippet_opportunities = @()
    ambiguidades = @("Falha ao consultar o SerpApi para o tema informado.")
    missing_sources = @("google_search", "google_trends_related_queries")
    error = $_.Exception.Message
  } | ConvertTo-Json -Depth 30
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Set-Content -Path $OutputPath -Value $jsonOut -Encoding UTF8
  }
  $jsonOut
  exit 1
}
