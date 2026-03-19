param(
  [Parameter(Mandatory = $true)]
  [string]$Tema,

  [string]$OutputDir = "",

  [switch]$StopAfterPlanning
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

function Get-OptionalEnv([string]$Name, [string]$Default = "") {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Default
  }
  return $value
}

function Convert-TextToJsonObject {
  param(
    [string]$Text,
    [string]$Provider = ""
  )

  $trimmed = [string]$Text
  if ([string]::IsNullOrWhiteSpace($trimmed)) {
    throw "Resposta vazia da LLM."
  }

  $trimmed = $trimmed.Trim()
  $match = [regex]::Match($trimmed, '```(?:json)?\s*([\s\S]*?)\s*```')
  if ($match.Success) {
    $trimmed = $match.Groups[1].Value.Trim()
  }

  try {
    return ($trimmed | ConvertFrom-Json)
  }
  catch {
    $first = $trimmed.IndexOf('{')
    $last = $trimmed.LastIndexOf('}')
    if ($first -ge 0 -and $last -gt $first) {
      $candidate = $trimmed.Substring($first, $last - $first + 1)
      try {
        return ($candidate | ConvertFrom-Json)
      }
      catch {
        $repairPrompt = @"
Converta o conteudo abaixo em JSON estritamente valido.

Regras:
- preserve o maximo possivel do conteudo
- nao adicione comentarios
- nao use markdown
- retorne apenas um objeto JSON valido

Conteudo:
$candidate
"@
        return (Invoke-LlmJson -SystemPrompt "Voce corrige JSON invalido e retorna apenas JSON valido." -UserPrompt $repairPrompt -Model "" -Provider $Provider)
      }
    }
    throw
  }
}

function Invoke-LlmJson {
  param(
    [string]$SystemPrompt,
    [string]$UserPrompt,
    [string]$Model = "",
    [string]$Provider = ""
  )

  $provider = if ([string]::IsNullOrWhiteSpace($Provider)) {
    (Get-OptionalEnv -Name "LLM_PROVIDER" -Default "anthropic").ToLowerInvariant()
  } else {
    $Provider.ToLowerInvariant()
  }

  if ($provider -eq "anthropic") {
    $apiKey = Get-RequiredEnv "ANTHROPIC_API_KEY"
    $resolvedModel = if ([string]::IsNullOrWhiteSpace($Model)) { Get-OptionalEnv -Name "ANTHROPIC_MODEL" -Default "claude-sonnet-4-5" } else { $Model }
    $headers = @{
      "x-api-key" = $apiKey
      "anthropic-version" = "2023-06-01"
      "content-type" = "application/json"
    }
    $body = @{
      model = $resolvedModel
      max_tokens = 4096
      temperature = 0.4
      system = $SystemPrompt
      messages = @(
        @{
          role = "user"
          content = @(
            @{
              type = "text"
              text = $UserPrompt
            }
          )
        }
      )
    }
    $json = $body | ConvertTo-Json -Depth 30 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
      $response = Invoke-RestMethod -Method Post -Uri "https://api.anthropic.com/v1/messages" -Headers $headers -Body $bytes -ContentType "application/json; charset=utf-8"
    }
    catch {
      if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $errorBody = $reader.ReadToEnd()
        throw "Anthropic API error: $errorBody"
      }
      throw
    }
    $text = ((@($response.content) | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "")
    return (Convert-TextToJsonObject -Text $text -Provider $provider)
  }

  $apiKey = Get-RequiredEnv "OPENAI_API_KEY"
  $resolvedModel = if ([string]::IsNullOrWhiteSpace($Model)) { Get-OptionalEnv -Name "OPENAI_MODEL" -Default "gpt-4o-mini" } else { $Model }
  $headers = @{
    "Authorization" = "Bearer $apiKey"
    "Content-Type"  = "application/json"
  }

  $body = @{
    model = $resolvedModel
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
  return ($response.choices[0].message.content | ConvertFrom-Json)
}

function Save-Json {
  param([string]$Path, [object]$Data)
  $cleanData = Repair-TextTree -Value $Data
  $cleanData | ConvertTo-Json -Depth 50 | Set-Content -Path $Path -Encoding UTF8
}

function Convert-Cp1252SegmentToUtf8 {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }

  try {
    $bytes = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetBytes($Text)
    $candidate = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($candidate.IndexOf([char]0xFFFD) -ge 0) {
      return $Text
    }
    return $candidate
  }
  catch {
    return $Text
  }
}

function Repair-MojibakeString {
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }

  $flagA = [char]0x00C3
  $flagB = [char]0x00C2
  $flagC = [char]0x00E2
  if (($Text.IndexOf($flagA) -lt 0) -and ($Text.IndexOf($flagB) -lt 0) -and ($Text.IndexOf($flagC) -lt 0)) {
    return $Text
  }

  $fixed = $Text
  for ($pass = 0; $pass -lt 3; $pass++) {
    $builder = New-Object System.Text.StringBuilder
    $changed = $false

    for ($i = 0; $i -lt $fixed.Length; $i++) {
      $current = $fixed[$i]
      if (($current -ne $flagA) -and ($current -ne $flagB) -and ($current -ne $flagC)) {
        [void]$builder.Append($current)
        continue
      }

      $segmentBuilder = New-Object System.Text.StringBuilder
      [void]$segmentBuilder.Append($current)
      $j = $i + 1
      while ($j -lt $fixed.Length) {
        $next = $fixed[$j]
        $code = [int][char]$next
        if (($next -eq $flagA) -or ($next -eq $flagB) -or ($next -eq $flagC) -or ($code -ge 0x0080 -and $code -le 0x00FF)) {
          [void]$segmentBuilder.Append($next)
          $j++
          continue
        }
        break
      }

      $segment = $segmentBuilder.ToString()
      $candidate = Convert-Cp1252SegmentToUtf8 -Text $segment
      if ($candidate -ne $segment) {
        $changed = $true
      }
      [void]$builder.Append($candidate)
      $i = $j - 1
    }

    $candidateText = $builder.ToString()
    $candidateText = $candidateText.Replace("Â ", " ").Replace("Â ", " ")
    if (-not $changed -or $candidateText -eq $fixed) {
      $fixed = $candidateText
      break
    }
    $fixed = $candidateText
  }

  return $fixed
}

function Normalize-FinalHtml {
  param([string]$Html)

  if ([string]::IsNullOrEmpty($Html)) { return $Html }

  $fixed = Repair-MojibakeString -Text $Html
  $fixed = $fixed.Replace("Â ", " ").Replace("Â ", " ")
  return $fixed
}

function Repair-TextTree {
  param([object]$Value)

  if ($null -eq $Value) { return $null }

  if ($Value -is [string]) {
    return (Repair-MojibakeString -Text $Value)
  }

  if ($Value -is [System.Collections.ArrayList]) {
    $items = @()
    foreach ($item in $Value) {
      $items += @(Repair-TextTree -Value $item)
    }
    return ,$items
  }

  if ($Value -is [System.Array]) {
    $items = @()
    foreach ($item in $Value) {
      $items += @(Repair-TextTree -Value $item)
    }
    return ,$items
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $map = @{}
    foreach ($key in $Value.Keys) {
      $map[$key] = Repair-TextTree -Value $Value[$key]
    }
    return $map
  }

  if ($Value -is [pscustomobject] -or $Value.PSObject.Properties.Count -gt 0) {
    $obj = [ordered]@{}
    foreach ($prop in $Value.PSObject.Properties) {
      $obj[$prop.Name] = Repair-TextTree -Value $prop.Value
    }
    return [pscustomobject]$obj
  }

  return $Value
}

function Get-PowerShellExecutable {
  $pwsh = Get-Command "pwsh" -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) { return $pwsh.Source }

  $powershell = Get-Command "powershell" -ErrorAction SilentlyContinue
  if ($null -ne $powershell) { return $powershell.Source }

  throw "Nenhum executavel PowerShell encontrado. Instale pwsh ou powershell no ambiente."
}

function Get-TempFilePath {
  param([string]$Extension = ".json")

  $tempDir = [System.IO.Path]::GetTempPath()
  if ([string]::IsNullOrWhiteSpace($tempDir)) {
    throw "Nao foi possivel resolver diretorio temporario do sistema."
  }

  return (Join-Path $tempDir ([System.IO.Path]::GetRandomFileName() + $Extension))
}

function Run-JsonScript {
  param(
    [string]$ScriptPath,
    [string[]]$Arguments
  )

  $tempPath = Get-TempFilePath -Extension ".json"
  $powerShellExe = Get-PowerShellExecutable
  try {
    $output = & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments "-OutputPath" $tempPath
  }
  finally {
    $null = $output
  }

  if (Test-Path $tempPath) {
    $text = (Get-Content -Path $tempPath -Raw -Encoding UTF8).Trim()
    Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
  }
  else {
    $text = ""
  }

  if ([string]::IsNullOrWhiteSpace($text)) {
    throw "Script sem saida JSON: $ScriptPath"
  }
  return (Repair-TextTree -Value ($text | ConvertFrom-Json))
}

function Split-HBlocks {
  param([object[]]$Blocks)

  $hs = New-Object System.Collections.ArrayList
  foreach ($block in $Blocks) {
    [void]$hs.Add($block)
  }
  return @($hs)
}

function Get-FirstCourseUrl {
  param([object]$Courses)

  if ($null -eq $Courses) { return "" }
  if ($Courses -is [System.Array] -and $Courses.Count -gt 0) {
    return [string]$Courses[0].url
  }
  if ($Courses.url) { return [string]$Courses.url }
  return ""
}

function Normalize-PlanForWriters {
  param([object]$Plan)

  foreach ($block in @($Plan.blocos)) {
    if ($null -eq $block.PSObject.Properties["objetivo_SEO"] -and $null -ne $block.PSObject.Properties["objetivo_seo"]) {
      $block | Add-Member -NotePropertyName "objetivo_SEO" -NotePropertyValue $block.objetivo_seo
    }
  }
}

function Repair-ArticlePlan {
  param(
    [object]$Plan,
    [object]$ApprovedTopic,
    [object]$ResearchPack,
    [object]$CourseMatch
  )

  $repaired = Invoke-LlmJson `
    -SystemPrompt "Voce revisa article_plan.json para manter fidelidade editorial e schema fixo. Retorne apenas JSON valido." `
    -Provider "anthropic" `
    -UserPrompt @"
Revise o article_plan abaixo e devolva o mesmo schema, corrigindo apenas o necessario.

Objetivo:
- manter o plano estritamente fiel ao approved topic
- remover blocos, FAQs, imagens e CTAs fora do escopo
- nao introduzir assuntos paralelos, datas comemorativas diferentes ou ganchos laterais
- manter a hierarquia H2/H3 e a ordem sequencial
- preservar 3 ou mais H2
- usar apenas informacoes alinhadas ao research pack

Regras obrigatorias:
- meta.titulo deve ser exatamente "$($ApprovedTopic.titulo)"
- meta.slug deve ser exatamente "$($ApprovedTopic.slug)"
- meta.palavra_chave deve ser exatamente "$($ApprovedTopic.palavra_chave)"
- h1 deve ser igual ou muito proximo de "$($ApprovedTopic.titulo)"
- todos os H2 e H3 devem permanecer dentro do canonical_topic "$($ApprovedTopic.canonical_topic)"
- nao citar Dia das Criancas, volta as aulas, semana da inclusao ou qualquer tema nao presente no recorte aprovado, salvo se estiver explicitamente no tema central
- mantenha as mesmas chaves do schema e nunca omita campos

Approved topic:
$($ApprovedTopic | ConvertTo-Json -Depth 20)

Research pack:
$($ResearchPack | ConvertTo-Json -Depth 20)

Course match:
$($CourseMatch | ConvertTo-Json -Depth 20)

Article plan:
$($Plan | ConvertTo-Json -Depth 30)
"@

  return $repaired
}

function Set-ObjectField {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Value
  )

  if ($null -eq $Object.PSObject.Properties[$Name]) {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
  else {
    $Object.$Name = $Value
  }
}

function Convert-FaqToHtml {
  param([object]$FaqValue)

  if ($FaqValue -is [string]) {
    return (Repair-MojibakeString -Text $FaqValue)
  }

  $faqTitle = if ($null -ne $FaqValue.h2) { $FaqValue.h2 } elseif ($null -ne $FaqValue.titulo) { $FaqValue.titulo } else { $null }
  $faqItems = if ($null -ne $FaqValue.questions) { $FaqValue.questions } elseif ($null -ne $FaqValue.perguntas) { $FaqValue.perguntas } else { $null }

  if ($null -ne $faqTitle -and $null -ne $faqItems) {
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("<h2>$([string](Repair-MojibakeString -Text $faqTitle))</h2>")
    foreach ($item in @($faqItems)) {
      $questionSource = if ($null -ne $item.h3) { $item.h3 } elseif ($null -ne $item.pergunta) { $item.pergunta } else { "" }
      $answerSource = if ($null -ne $item.p) { $item.p } elseif ($null -ne $item.resposta) { $item.resposta } elseif ($null -ne $item.resposta_curta) { $item.resposta_curta } else { "" }
      $question = Repair-MojibakeString -Text ([string]$questionSource)
      $answer = Repair-MojibakeString -Text ([string]$answerSource)
      [void]$parts.Add("<h3>$question</h3>")
      [void]$parts.Add("<p>$answer</p>")
    }
    return ($parts -join "")
  }

  return (Repair-MojibakeString -Text ([string]$FaqValue))
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $OutputDir = Join-Path $PSScriptRoot "..\..\..\test-output\orchestrator-$stamp"
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$decisionLog = New-Object System.Collections.ArrayList

$topicResearchScript = Join-Path $PSScriptRoot "..\..\..\skills\topic-research\scripts\run_topic_research.ps1"
$researchPack = Run-JsonScript -ScriptPath $topicResearchScript -Arguments @("-Tema", $Tema)
Save-Json -Path (Join-Path $OutputDir "01-research-pack.json") -Data $researchPack
[void]$decisionLog.Add(@{ step = "topic-research"; status = $researchPack.status })

$validation = Invoke-LlmJson `
  -SystemPrompt "Voce valida temas editoriais para servidor publico. Responda apenas JSON valido." `
  -Provider "openai" `
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
[void]$decisionLog.Add(@{ step = "topic-validation"; status = $validation.decision })

if ($validation.decision -eq "rejected") {
  throw "Tema rejeitado na validacao."
}

$seoScript = Join-Path $PSScriptRoot "..\..\..\skills\seo-title-slug\scripts\run_seo_title_slug.ps1"
$approvedTopic = Run-JsonScript -ScriptPath $seoScript -Arguments @(
  "-TemaOriginal", $Tema,
  "-ResearchPackPath", (Join-Path $OutputDir "01-research-pack.json"),
  "-ValidationPath", (Join-Path $OutputDir "02-topic-validation.json")
)
Save-Json -Path (Join-Path $OutputDir "03-approved-topic.json") -Data $approvedTopic
[void]$decisionLog.Add(@{ step = "seo-title-slug"; status = "ok"; slug = $approvedTopic.slug })

$duplicateScript = Join-Path $PSScriptRoot "..\..\..\skills\duplicate-check\scripts\check_duplicates.ps1"
$duplicateCheck = Run-JsonScript -ScriptPath $duplicateScript -Arguments @(
  "-Title", [string]$approvedTopic.titulo,
  "-Slug", [string]$approvedTopic.slug,
  "-Keyword", [string]$approvedTopic.palavra_chave
)
Save-Json -Path (Join-Path $OutputDir "04-duplicate-check.json") -Data $duplicateCheck
[void]$decisionLog.Add(@{ step = "duplicate-check"; status = $duplicateCheck.status })

if ($duplicateCheck.status -eq "duplicate_exact" -or $duplicateCheck.status -eq "duplicate_semantic") {
  throw "Tema bloqueado por duplicidade: $($duplicateCheck.status)"
}

$courseScript = Join-Path $PSScriptRoot "..\..\..\skills\course-match\scripts\match_courses.ps1"
$courseMatch = Run-JsonScript -ScriptPath $courseScript -Arguments @(
  "-Keyword", [string]$approvedTopic.palavra_chave,
  "-Title", [string]$approvedTopic.titulo
)
Save-Json -Path (Join-Path $OutputDir "05-course-match.json") -Data $courseMatch
[void]$decisionLog.Add(@{ step = "course-match"; status = if ($courseMatch.error) { "error" } else { "ok" } })

$plannerScript = Join-Path $PSScriptRoot "..\..\..\skills\article-planner\scripts\run_article_planner.ps1"
$articlePlan = Run-JsonScript -ScriptPath $plannerScript -Arguments @(
  "-ApprovedTopicPath", (Join-Path $OutputDir "03-approved-topic.json"),
  "-ResearchPackPath", (Join-Path $OutputDir "01-research-pack.json"),
  "-CourseMatchPath", (Join-Path $OutputDir "05-course-match.json")
)
$articlePlan = Repair-ArticlePlan -Plan $articlePlan -ApprovedTopic $approvedTopic -ResearchPack $researchPack -CourseMatch $courseMatch
$articlePlan = Repair-TextTree -Value $articlePlan
if ($null -eq $articlePlan.meta) {
  $articlePlan | Add-Member -NotePropertyName "meta" -NotePropertyValue ([pscustomobject]@{})
}
Set-ObjectField -Object $articlePlan.meta -Name "titulo" -Value $approvedTopic.titulo
Set-ObjectField -Object $articlePlan.meta -Name "slug" -Value $approvedTopic.slug
Set-ObjectField -Object $articlePlan.meta -Name "palavra_chave" -Value $approvedTopic.palavra_chave
Set-ObjectField -Object $articlePlan -Name "h1" -Value $approvedTopic.titulo
Save-Json -Path (Join-Path $OutputDir "06-article-plan.json") -Data $articlePlan
[void]$decisionLog.Add(@{ step = "article-planner"; status = "ok"; blocos = @($articlePlan.blocos).Count })

if ($StopAfterPlanning) {
  @{
    tema = $Tema
    output_dir = $OutputDir
    status = "stopped_after_planning"
    generated_files = @(
      "01-research-pack.json",
      "02-topic-validation.json",
      "03-approved-topic.json",
      "04-duplicate-check.json",
      "05-course-match.json",
      "06-article-plan.json"
    )
    decision_log = @($decisionLog)
  } | ConvertTo-Json -Depth 20
  return
}

Normalize-PlanForWriters -Plan $articlePlan

$primaryCourseUrl = Get-FirstCourseUrl -Courses $articlePlan.cursos_relacionados
$coursesPromptJson = ($articlePlan.cursos_relacionados | ConvertTo-Json -Depth 20 -Compress)
$distributor = Invoke-LlmJson `
  -SystemPrompt "Voce e um agente de apoio editorial. Divida blocos sem alterar conteudo e retorne apenas JSON valido." `
  -Provider "openai" `
  -UserPrompt @"
Voce e um agente de apoio editorial. Sua missao: receber um PLANEJAMENTO DE ARTIGO em JSON e dividir os blocos entre 3 redatores, SEM alterar nada do conteudo.

Entrada do planejamento (JSON):
Titulo: $($articlePlan.meta.titulo)
Slug: $($articlePlan.meta.slug)
Palavra-chave: $($articlePlan.meta.palavra_chave)
Meta-title: $($articlePlan.meta.meta_title)
Meta Description: $($articlePlan.meta.meta_description)
H1: $($articlePlan.h1)
Planejamento dos Hs: $($articlePlan.blocos | ConvertTo-Json -Depth 20 -Compress)
FAQ: $($articlePlan.faq | ConvertTo-Json -Depth 20 -Compress)
Links internos: $($articlePlan.links_internos | ConvertTo-Json -Depth 20 -Compress)
Cursos relacionados: $coursesPromptJson
Links externos: $($articlePlan.links_externos | ConvertTo-Json -Depth 20 -Compress)
CTAs: $($articlePlan.ctas | ConvertTo-Json -Depth 20 -Compress)

REGRAS FUNDAMENTAIS:
1) Nao altere, resuma, traduza ou reordene nenhum campo do planejamento original.
2) A divisao e apenas de responsabilidade por bloco, de forma sequencial.
3) FAQ inteiro deve ser atribuido ao redator_3 e tambem mantido no topo.
4) Imagens nao vao para redatores. Mantenha imagens_sugeridas, links_internos, links_externos e ctas no topo.
5) Preserve a hierarquia: cada H3 mantem seu parent_id.
6) A saida deve ser JSON valido e seguir exatamente este formato:
{
  "meta": {},
  "h1": "",
  "distribuicao": {
    "redator_1": [],
    "redator_2": [],
    "redator_3": [],
    "observacoes": "Nao editar conteudo. Ordem sequencial mantida. H3 permanece vinculado ao H2 via parent_id."
  },
  "faq": [],
  "faq_responsavel": "redator_3",
  "imagens_sugeridas": [],
  "links_internos": [],
  "links_externos": [],
  "ctas": []
}

INSTRUCOES DETALHADAS DE ALOCACAO:
- Percorra o array blocos em ordem.
- Quando encontrar um H2, aloque-o ao proximo redator da fila (1 -> 2 -> 3 -> 1).
- Aloque todos os H3 cujo parent_id corresponda a esse H2 para o mesmo redator.
- Continue ate acabar os blocos.
- Ao final, copie o faq do original para o topo e tambem para distribuicao.redator_3.
- Copie imagens_sugeridas, links_internos, links_externos e ctas do original para o topo.

RETORNE APENAS O JSON FINAL.
"@
$distributor = Repair-TextTree -Value $distributor
Save-Json -Path (Join-Path $OutputDir "07-distribuidor.json") -Data $distributor

$writerPromptHeader = @"
Voce e um redator brasileiro especialista em SEO, AEO (Answer Engine Optimization) e GEO (Generative Engine Optimization), com 10+ anos de experiencia. Sua tarefa e escrever APENAS a sua parte do artigo em HTML, com base no conjunto de blocos (H2/H3) fornecido abaixo. Produza texto natural, humano e didatico, usando tecnicas avancadas de SEO/AEO/GEO para competir por 1o lugar no Google e em IAs.
"@

$writerPromptRules = @"
Regras inviolaveis:
- Nao crie, nao edite e nao reordene titulos. Use exatamente os H2/H3 recebidos.
- Escreva somente o conteudo dos blocos que recebeu.
- Nao insira imagens.
- Insira o link do curso em formato HTML $coursesPromptJson de forma natural, pelo menos 1 vez em cada H2.
- Se algum bloco vier com "objetivo_SEO" indicando lista/snippet, comece a secao com uma resposta curta e direta e depois desenvolva o conteudo.
- Quando indicado "How-to" ou "lista", inclua uma lista <ul> ou <ol> com 4-6 itens.
- Use linguagem humana brasileira, frases curtas (<= 20 palavras) e paragrafos leves (<= 4 linhas).
- Destaque termos-chave e frases importantes com <strong> (2-4 destaques por H2/H3).
- Varie ritmo e fluidez. Evite jargao desnecessario.
- Respeite a "estimativa_palavras" com tolerancia de +-15%.
- Utilize a palavra-chave principal e variacoes semanticas.
- Sempre que voce se referir ao Educamundo utilize a palavra assim "Educamundo".

FORMATACAO HTML:
- Use apenas: <h2>, <h3>, <p>, <strong>, <em>, <ul>, <ol>, <li>, <a>
- Estrutura por bloco:
  - Renderize o titulo como <h2> ou <h3>.
  - Em seguida, escreva o conteudo em 2-4 paragrafos <p>.
  - Quando fizer sentido, inclua uma lista com 4-6 itens.
  - Nao use </br>.

OTIMIZACAO:
- Integre naturalmente a palavra-chave do bloco e "kw_alvo".
- No 1o paragrafo de cada H2/H3, de uma resposta clara e direta em 1 frase.
- Expanda com exemplos, dicas e micro-historias.
- Sempre que possivel, insira listas para facilitar a escaneabilidade.

SAIDA:
- Retorne APENAS um JSON com a chave "texto 1".
"@

$writer1 = Invoke-LlmJson -SystemPrompt "Redator 1 de blocos HTML. Retorne apenas JSON valido." -Provider "anthropic" -UserPrompt @"
$writerPromptHeader

ENTRADA (somente seus blocos, na ordem):
$($distributor.distribuicao.redator_1 | ConvertTo-Json -Depth 20 -Compress)

$writerPromptRules
"@
$writer1 = Repair-TextTree -Value $writer1
Set-ObjectField -Object $writer1 -Name "writer_role" -Value "redator_1"
Save-Json -Path (Join-Path $OutputDir "08-writer-redator-1.json") -Data $writer1

$writer2 = Invoke-LlmJson -SystemPrompt "Redator 2 de blocos HTML. Retorne apenas JSON valido." -Provider "anthropic" -UserPrompt @"
$writerPromptHeader

ENTRADA (somente seus blocos, na ordem):
$($distributor.distribuicao.redator_2 | ConvertTo-Json -Depth 20 -Compress)

$writerPromptRules
"@
$writer2 = Repair-TextTree -Value $writer2
Set-ObjectField -Object $writer2 -Name "writer_role" -Value "redator_2"
Save-Json -Path (Join-Path $OutputDir "09-writer-redator-2.json") -Data $writer2

$writer3 = Invoke-LlmJson -SystemPrompt "Redator 3 de blocos HTML. Retorne apenas JSON valido." -Provider "anthropic" -UserPrompt @"
$writerPromptHeader

ENTRADA (somente seus blocos, na ordem):
$($distributor.distribuicao.redator_3 | ConvertTo-Json -Depth 20 -Compress)

$writerPromptRules
"@
$writer3 = Repair-TextTree -Value $writer3
Set-ObjectField -Object $writer3 -Name "writer_role" -Value "redator_3"
Save-Json -Path (Join-Path $OutputDir "10-writer-redator-3.json") -Data $writer3

$writerFinal = Invoke-LlmJson `
  -SystemPrompt "Voce e um redator brasileiro especialista em SEO, AEO e GEO, com mais de 15 anos de experiencia. Retorne apenas JSON valido." `
  -Provider "anthropic" `
  -UserPrompt @"
Voce e um redator brasileiro especialista em SEO, AEO (Answer Engine Optimization) e GEO (Generative Engine Optimization), com mais de 15 anos de experiencia.
Sua missao e gerar a introducao, a conclusao, classificar a categoria do artigo e construir o FAQ em HTML com base nos conteudos ja escritos pelos redatores.
- Sempre que voce se referir ao Educamundo utilize a palavra assim "Educamundo".

## Entradas
- Texto do Redator 1: $([string]$writer1.'texto 1')
- Texto do Redator 2: $([string]$writer2.'texto 1')
- Texto do Redator 3: $([string]$writer3.'texto 1')
- Link do curso relacionado: $coursesPromptJson
- FAQ (array de pergunta/resposta): $($distributor.faq | ConvertTo-Json -Depth 20 -Compress)

O nome do curso deve ser buscado a partir do link do curso. Se nao houver titulo explicito na URL, derive um nome legivel a partir do caminho.
A categoria do artigo deve ser escolhida apenas entre estas opcoes, sem alterar a escrita:
Administracao
Artes
Assistencia social
Bem Estar e Cotidiano
Certificacao
Comunicacao e Marketing
Cultura
Dicas
Direito
Educacao
Educacao Inclusiva
Educacao Infantil
Estudo
Formacao Profissional
Idiomas
Industria e Tecnologia
Informatica
Meio Ambiente
Mercado de Trabalho
Psicologia
Recursos Humanos
Saude
Transito

## Regras de Producao
### Introducao (HTML)
- Gere uma introducao cativante e persuasiva.
- Estruture em minimo 2 paragrafos com <p>.
- Use <strong> para realcar termos importantes.
- Nao use </br>.

### Conclusao (HTML + venda do curso)
- Crie um H2 utilizando o nome do curso extraido do link; o titulo deve ser otimizado com SEO + AEO + GEO.
- Abaixo do H2, escreva uma conclusao que venda o curso do Educamundo, com no minimo 3 paragrafos <p>.
- Destaque beneficios e diferenciais do Educamundo:
  - Mais de 1.500 cursos online.
  - Certificados opcionais de 5h a 420h.
  - Certificados usados para licenca capacitacao, progressao de carreira, prova de titulos, horas complementares e para incrementar o curriculo.
  - Mais de 1 milhao de alunos.
  - Pacote Master: R$ 79,90 para acessar todos os cursos.
- Insira o link do curso em pelo menos 3 pontos naturais no texto.
- Use <strong> para reforcar os principais beneficios.
- Nao use </br>.

### FAQ (HTML)
- Construa uma secao de FAQ em HTML a partir da entrada FAQ.
- O titulo do FAQ deve ser um <h2> otimizado. Nao use apenas FAQ.
- Para cada item: pergunta em <h3> e resposta em <p>.
- Caso a entrada FAQ esteja vazia ou insuficiente, crie 3 a 5 perguntas/respostas relevantes.
- Nao insira links no FAQ.
- Nao use </br>.

### Categoria
- Atribua o artigo a UMA categoria da lista fornecida.

## SEO, AEO e GEO
- Primeira frase de cada secao deve entregar uma resposta direta.
- Varie semantica.
- Escaneabilidade: paragrafos curtos.
- Precisao e utilidade: evite rodeios.

## Saida esperada (JSON)
Retorne APENAS um JSON com quatro chaves:
- "introducao"
- "conclusao"
- "categoria"
- "faq"
"@
$writerFinal = Repair-TextTree -Value $writerFinal
Set-ObjectField -Object $writerFinal -Name "writer_role" -Value "redator_final"
Save-Json -Path (Join-Path $OutputDir "11-writer-final.json") -Data $writerFinal

$articleBody = @(
  [string]$writer1.'texto 1'
  [string]$writer2.'texto 1'
  [string]$writer3.'texto 1'
) -join ""

$articleFinal = @{
  meta = $articlePlan.meta
  h1 = $articlePlan.h1
  introducao = Normalize-FinalHtml -Html ([string]$writerFinal.introducao)
  corpo_html = Normalize-FinalHtml -Html $articleBody
  faq_html = Normalize-FinalHtml -Html (Convert-FaqToHtml -FaqValue $writerFinal.faq)
  conclusao = Normalize-FinalHtml -Html ([string]$writerFinal.conclusao)
  categoria = Repair-MojibakeString -Text ([string]$writerFinal.categoria)
  revision_notes = @("Montado pelo article-orchestrator com distribuidor + 3 redatores + redator final.")
}
Save-Json -Path (Join-Path $OutputDir "11-article-final.json") -Data $articleFinal

$imagePackage = Invoke-LlmJson `
  -SystemPrompt "Voce cria pacote textual de imagem para artigo. Responda apenas JSON valido." `
  -Provider "openai" `
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
if ($null -ne $imagePackage.image_package) { $imagePackage = $imagePackage.image_package }
$imagePackage = Repair-TextTree -Value $imagePackage
Save-Json -Path (Join-Path $OutputDir "12-image-package.json") -Data $imagePackage

$publishPackage = @{
  ready_to_publish = $true
  wordpress = @{
    title = $articleFinal.meta.titulo
    slug = $articleFinal.meta.slug
    status = "draft"
    content = Normalize-FinalHtml -Html ($articleFinal.introducao + $articleFinal.corpo_html + $articleFinal.faq_html + $articleFinal.conclusao)
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
    decision_log = @($decisionLog)
  }
  errors = @()
}
Save-Json -Path (Join-Path $OutputDir "13-publish-package.json") -Data $publishPackage

@{
  tema = $Tema
  title = $approvedTopic.titulo
  slug = $approvedTopic.slug
  duplicate_status = $duplicateCheck.status
  ready_to_publish = $publishPackage.ready_to_publish
  output_dir = $OutputDir
} | ConvertTo-Json -Depth 20
