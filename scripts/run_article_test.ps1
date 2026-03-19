param(
  [Parameter(Mandatory = $true)]
  [string]$Tema,

  [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"

function Get-RequiredEnv([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Variavel de ambiente obrigatoria ausente: $Name"
  }
  return $value
}

function Get-PowerShellExecutable {
  $pwsh = Get-Command "pwsh" -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) { return $pwsh.Source }

  $powershell = Get-Command "powershell" -ErrorAction SilentlyContinue
  if ($null -ne $powershell) { return $powershell.Source }

  throw "Nenhum executavel PowerShell encontrado. Instale pwsh ou powershell no ambiente."
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

function New-LiveResearchPack {
  param(
    [string]$Tema
  )

  $search = Invoke-SerpApiGet -Query @{
    engine = "google"
    q = $Tema
    gl = "br"
    hl = "pt-br"
    google_domain = "google.com.br"
  }

  $trends = $null
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
  }

  $candidateQueries = @()
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'

  if ($null -ne $search.search_parameters.q) {
    [void]$seen.Add([string]$search.search_parameters.q)
    $candidateQueries += @{
      query = [string]$search.search_parameters.q
      intent = "informacional"
      source = "google"
    }
  }

  foreach ($item in @($search.related_searches)) {
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
    if ($null -eq $trends -or $null -eq $trends.related_queries.$bucket) { continue }
    foreach ($item in @($trends.related_queries.$bucket)) {
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
  foreach ($item in @($search.related_questions)) {
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
  foreach ($item in @($search.organic_results)) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.title)) { continue }
    $organic += @{
      title = [string]$item.title
      snippet = if ([string]::IsNullOrWhiteSpace([string]$item.snippet)) { $null } else { [string]$item.snippet }
      url = if ([string]::IsNullOrWhiteSpace([string]$item.link)) { $null } else { [string]$item.link }
    }
  }

  $relatedSearches = @()
  foreach ($item in @($search.related_searches)) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.query)) { continue }
    $relatedSearches += [string]$item.query
  }

  foreach ($bucket in @("rising", "top")) {
    if ($null -eq $trends -or $null -eq $trends.related_queries.$bucket) { continue }
    foreach ($item in @($trends.related_queries.$bucket)) {
      if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.query)) { continue }
      $query = [string]$item.query
      if ($relatedSearches -notcontains $query) {
        $relatedSearches += $query
      }
    }
  }

  return @{
    status = "ok"
    tema = $Tema
    seed_keyword = if ($null -ne $search.search_parameters.q) { [string]$search.search_parameters.q } else { $Tema }
    candidate_queries = $candidateQueries
    people_also_ask = $paa
    related_searches = $relatedSearches
    organic_highlights = $organic
    search_intent_summary = "Consulta informacional baseada em sinais reais de Google Search, People Also Ask, related searches e Google Trends."
    snippet_opportunities = @("lista", "faq", "passo a passo")
    ambiguidades = @()
    missing_sources = @()
  }
}

function Invoke-OpenAIJson {
  param(
    [string]$SystemPrompt,
    [string]$UserPrompt,
    [string]$Model = "gpt-4o-mini"
  )

  $apiKey = Get-RequiredEnv "OPENAI_API_KEY"
  $headers = @{
    "Authorization" = "Bearer $apiKey"
    "Content-Type"  = "application/json"
  }

  $body = @{
    model = $Model
    messages = @(
      @{ role = "system"; content = $SystemPrompt },
      @{ role = "user"; content = $UserPrompt }
    )
    response_format = @{ type = "json_object" }
    temperature = 0.4
  }

  $json = $body | ConvertTo-Json -Depth 30 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $response = Invoke-RestMethod -Method Post -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $bytes -ContentType "application/json; charset=utf-8"
  $content = $response.choices[0].message.content
  return $content | ConvertFrom-Json
}

function Save-Json {
  param(
    [string]$Path,
    [object]$Data
  )

  $Data | ConvertTo-Json -Depth 50 | Set-Content -Path $Path -Encoding UTF8
}

function Split-Blocks {
  param([array]$Blocks)

  $groups = @(
    New-Object System.Collections.ArrayList,
    New-Object System.Collections.ArrayList,
    New-Object System.Collections.ArrayList
  )

  $writerIndex = 0
  $i = 0
  while ($i -lt $Blocks.Count) {
    $block = $Blocks[$i]
    if ($block.nivel -eq "H2") {
      [void]$groups[$writerIndex].Add($block)
      $parentId = $block.id_bloco
      $i++
      while ($i -lt $Blocks.Count -and $Blocks[$i].nivel -eq "H3" -and $Blocks[$i].parent_id -eq $parentId) {
        [void]$groups[$writerIndex].Add($Blocks[$i])
        $i++
      }
      $writerIndex = ($writerIndex + 1) % 3
      continue
    }
    [void]$groups[$writerIndex].Add($block)
    $i++
  }

  return @($groups[0], $groups[1], $groups[2])
}

function Run-JsonScript {
  param(
    [string]$ScriptPath,
    [string[]]$Arguments
  )

  $powerShellExe = Get-PowerShellExecutable
  $output = & $powerShellExe -ExecutionPolicy Bypass -File $ScriptPath @Arguments
  $text = ($output | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "Script sem saida JSON: $ScriptPath"
  }
  return $text | ConvertFrom-Json
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $OutputDir = Join-Path $PSScriptRoot "..\\test-output\\$stamp"
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$jobContext = @{
  tema = $Tema
  locale = "pt-BR"
  pais = "BR"
  created_at = (Get-Date).ToString("s")
}

$researchPack = New-LiveResearchPack -Tema $Tema
Save-Json -Path (Join-Path $OutputDir "01-research-pack.json") -Data $researchPack

$validation = Invoke-OpenAIJson `
  -SystemPrompt "Voce valida temas editoriais para servidor publico. Responda apenas JSON valido." `
  -UserPrompt @"
Avalie o tema abaixo para servidor publico e devolva exatamente estas chaves:
- decision: approved|refine|rejected
- reasoning: array de strings curtas
- scores: objeto com aderencia_publico, utilidade_pratica, potencial_busca, perenidade
- refined_angle: string ou null

Tema: $Tema
Research pack:
$($researchPack | ConvertTo-Json -Depth 20)
"@
Save-Json -Path (Join-Path $OutputDir "02-topic-validation.json") -Data $validation

if ($validation.decision -eq "rejected") {
  throw "Tema rejeitado na validacao."
}

$approvedTopic = Invoke-OpenAIJson `
  -SystemPrompt "Voce gera titulo, slug, palavra-chave e canonical_topic para artigo SEO. Responda apenas JSON valido." `
  -UserPrompt @"
Tema original: $Tema
Decision: $($validation.decision)
Refined angle: $($validation.refined_angle)
Research pack:
$($researchPack | ConvertTo-Json -Depth 20)

Retorne exatamente:
- tema_original
- titulo
- slug
- palavra_chave
- canonical_topic
- angulo_editorial
"@
Save-Json -Path (Join-Path $OutputDir "03-approved-topic.json") -Data $approvedTopic

$duplicateScript = Join-Path $PSScriptRoot "..\\skills\\duplicate-check\\scripts\\check_duplicates.ps1"
$duplicateCheck = Run-JsonScript -ScriptPath $duplicateScript -Arguments @(
  "-Title", [string]$approvedTopic.titulo,
  "-Slug", [string]$approvedTopic.slug,
  "-Keyword", [string]$approvedTopic.palavra_chave
)
Save-Json -Path (Join-Path $OutputDir "04-duplicate-check.json") -Data $duplicateCheck

if ($duplicateCheck.status -eq "duplicate_exact" -or $duplicateCheck.status -eq "duplicate_semantic") {
  throw "Tema bloqueado por duplicidade: $($duplicateCheck.status)"
}

$courseScript = Join-Path $PSScriptRoot "..\\skills\\course-match\\scripts\\match_courses.ps1"
$courseMatch = Run-JsonScript -ScriptPath $courseScript -Arguments @(
  "-Keyword", [string]$approvedTopic.palavra_chave,
  "-Title", [string]$approvedTopic.titulo
)
Save-Json -Path (Join-Path $OutputDir "05-course-match.json") -Data $courseMatch

$articlePlan = Invoke-OpenAIJson `
  -SystemPrompt "Voce cria article_plan.json para artigos SEO, AEO e GEO. Responda apenas JSON valido." `
  -UserPrompt @"
Crie um article_plan.json com estas chaves:
- meta { titulo, slug, palavra_chave, meta_title, meta_description }
- h1
- blocos [{ id_bloco, nivel, titulo, conteudo_brief, objetivo_seo, kw_alvo, estimativa_palavras, parent_id }]
- faq [{ pergunta, resposta_curta }]
- imagens_sugeridas [{ descricao, alt_text }]
- links_internos
- cursos_relacionados
- links_externos
- ctas

Use:
Approved topic:
$($approvedTopic | ConvertTo-Json -Depth 20)

Research pack:
$($researchPack | ConvertTo-Json -Depth 20)

Course match:
$($courseMatch | ConvertTo-Json -Depth 20)

Regras:
- minimo 3 H2
- cada H2 pode ter 1 a 3 H3
- links_externos apenas institucionais ou informativos
- cursos_relacionados deve aproveitar os cursos retornados
"@
Save-Json -Path (Join-Path $OutputDir "06-article-plan.json") -Data $articlePlan

$draftParts = @()
$draft = Invoke-OpenAIJson `
  -SystemPrompt "Voce escreve blocos de artigo em HTML simples e natural. Responda apenas JSON valido." `
  -UserPrompt @"
Escreva todos os blocos recebidos sem alterar a ordem.

Tags permitidas: <h2>, <h3>, <p>, <strong>, <em>, <ul>, <ol>, <li>, <a>

Blocos:
$($articlePlan.blocos | ConvertTo-Json -Depth 20)

Palavra-chave principal: $($articlePlan.meta.palavra_chave)
Cursos relacionados: $($articlePlan.cursos_relacionados | ConvertTo-Json -Depth 10)

Retorne exatamente:
- writer_id
- html
"@
$draft.writer_id = "writer_1"
$draftParts += $draft
Save-Json -Path (Join-Path $OutputDir "07-article-draft-parts.json") -Data $draftParts

$articleFinal = Invoke-OpenAIJson `
  -SystemPrompt "Voce consolida um artigo final em HTML. Responda apenas JSON valido." `
  -UserPrompt @"
Monte o article_final com estas chaves:
- meta
- h1
- introducao
- corpo_html
- faq_html
- conclusao
- categoria
- revision_notes

Approved topic:
$($approvedTopic | ConvertTo-Json -Depth 20)

Article plan:
$($articlePlan | ConvertTo-Json -Depth 20)

Draft parts:
$($draftParts | ConvertTo-Json -Depth 20)
"@
$articleFinal = if ($null -ne $articleFinal.article_final) { $articleFinal.article_final } else { $articleFinal }
Save-Json -Path (Join-Path $OutputDir "08-article-final.json") -Data $articleFinal

$imagePackage = Invoke-OpenAIJson `
  -SystemPrompt "Voce cria pacote textual de imagem para artigo. Responda apenas JSON valido." `
  -UserPrompt @"
Crie image_package com estas chaves:
- title
- nome_arquivo
- alt_text
- caption
- prompt_imagem
- negative_prompt
- aspect_ratio
- featured_image_notes

Article final:
$($articleFinal | ConvertTo-Json -Depth 20)
"@
$imagePackage = if ($null -ne $imagePackage.image_package) { $imagePackage.image_package } else { $imagePackage }
Save-Json -Path (Join-Path $OutputDir "09-image-package.json") -Data $imagePackage

$publishPackage = @{
  ready_to_publish = $true
  wordpress = @{
    title = $articleFinal.meta.titulo
    slug = $articleFinal.meta.slug
    status = "draft"
    content = ($articleFinal.introducao + $articleFinal.corpo_html + $articleFinal.faq_html + $articleFinal.conclusao)
    excerpt = $articleFinal.meta.meta_description
    category = $articleFinal.categoria
  }
  database = @{
    tema = $Tema
    palavra_chave = $approvedTopic.palavra_chave
    canonical_topic = $approvedTopic.canonical_topic
    duplicate_status = $duplicateCheck.status
  }
  media = @{
    image_package = $imagePackage
  }
  telemetry = @{
    output_dir = $OutputDir
    created_at = (Get-Date).ToString("s")
  }
  errors = @()
}
Save-Json -Path (Join-Path $OutputDir "10-publish-package.json") -Data $publishPackage

$summary = @{
  output_dir = $OutputDir
  tema = $Tema
  title = $approvedTopic.titulo
  slug = $approvedTopic.slug
  duplicate_status = $duplicateCheck.status
  courses = @($courseMatch.courses).Count
  ready_to_publish = $publishPackage.ready_to_publish
}

$summary | ConvertTo-Json -Depth 10
