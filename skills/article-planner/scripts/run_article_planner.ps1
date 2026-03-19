param(
  [Parameter(Mandatory = $true)]
  [string]$ApprovedTopicPath,

  [Parameter(Mandatory = $true)]
  [string]$ResearchPackPath,

  [Parameter(Mandatory = $true)]
  [string]$CourseMatchPath,

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
        $repaired = Invoke-LlmJson -SystemPrompt "Voce corrige JSON invalido e retorna apenas JSON valido." -UserPrompt $repairPrompt -Model "" -Provider $Provider
        return $repaired
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
    $response = Invoke-RestMethod -Method Post -Uri "https://api.anthropic.com/v1/messages" -Headers $headers -Body $bytes -ContentType "application/json; charset=utf-8"
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

$approvedTopic = Get-Content $ApprovedTopicPath -Raw | ConvertFrom-Json
$researchPack = Get-Content $ResearchPackPath -Raw | ConvertFrom-Json
$courseMatch = Get-Content $CourseMatchPath -Raw | ConvertFrom-Json

$coursesJson = if ($courseMatch.courses) {
  (($courseMatch.courses | ForEach-Object { $_.url }) -join ", ")
} else {
  ""
}

$result = Invoke-LlmJson `
  -SystemPrompt "Voce e um especialista em SEO, AEO (Answer Engine Optimization) e GEO (Generative Engine Optimization) com 20+ anos de experiencia. Gere um PLANEJAMENTO DE ARTIGO em um UNICO JSON, seguindo rigorosamente o esquema e a ordem solicitada. Nao explique e nao adicione comentarios fora do JSON." `
  -Provider "anthropic" `
  -UserPrompt @"
## Dados de entrada
- Titulo do artigo: $($approvedTopic.titulo)
- Slug do artigo: $($approvedTopic.slug)
- Palavra-chave principal: $($approvedTopic.palavra_chave)
- Questoes relacionadas (PAA): $($researchPack.people_also_ask | ConvertTo-Json -Depth 20 -Compress)
- Resultados organicos da palavra-chave: $($researchPack.organic_highlights | ConvertTo-Json -Depth 20 -Compress)
- Pesquisas relacionadas: $($researchPack.related_searches | ConvertTo-Json -Depth 20 -Compress)
- Candidate queries e tendencias: $($researchPack.candidate_queries | ConvertTo-Json -Depth 20 -Compress)
- Resumo de intencao de busca: $($researchPack.search_intent_summary)
- Cursos relacionados: $coursesJson

Atencao: os links dos cursos relacionados estao separados por virgula. Escolha apenas um ou dois cursos para utilizar no planejamento, sempre os mais relacionados com o tema e com a intencao do artigo.

## Regras editoriais
- Meta title <= 60 caracteres, iniciar com a palavra-chave.
- Meta description <= 155 caracteres, persuasiva, conter a palavra-chave.
- H1 deve ser igual ou muito proximo do titulo.
- Estrutura dos topicos: sequencial e hierarquica. Sempre que houver um H2, coloque o bloco do H2 seguido imediatamente dos H3 que pertencem a esse H2. Depois prossiga para o proximo H2.
- Para cada bloco (H2 ou H3), inclua "conteudo_brief" com orientacao objetiva do que escrever; use linguagem clara, escaneavel e com sugestoes de listas, exemplos, estatisticas e fontes quando fizer sentido.
- Otimize para SEO (SERP), AEO (SGE/PAAs/snippets) e GEO (respostas curtas e confiaveis para IAs). Sempre inclua "objetivo_SEO" e "kw_alvo".
- Mantenha sempre a mesma estrutura de chaves e ordem do JSON.
- Se um campo nao tiver conteudo, retorne string vazia "" ou array [] conforme o tipo esperado. Nunca omita chaves.
- Nao introduza datas comemorativas, eventos escolares ou ganchos editoriais que nao pertencam ao tema aprovado.
- Todos os H2, H3, FAQ, imagens e CTAs devem permanecer estritamente dentro do recorte do approved topic e do angulo editorial.
- O artigo deve equilibrar dois objetivos ao mesmo tempo:
  1. conversar diretamente com servidor publico e com a dor operacional do publico do Educamundo
  2. cobrir o maximo possivel de variacoes de busca realmente relevantes ao tema principal
- Nao produza artigo estreito demais. Preserve o foco, mas cubra tambem intencoes complementares visiveis em related searches, candidate queries, PAA e resultados organicos.
- "meta.titulo" deve ser exatamente o titulo aprovado.
- "meta.slug" deve ser exatamente o slug aprovado.
- "meta.palavra_chave" deve ser exatamente a palavra-chave aprovada.
- Nao troque o foco do artigo para assuntos adjacentes como Dia das Criancas, volta as aulas, semana da inclusao ou outras celebracoes, a menos que isso faca parte explicita do tema aprovado.

## Regras obrigatorias sobre cursos e links (Educamundo)
- E estritamente proibido citar, recomendar, comparar ou mencionar cursos, plataformas, instituicoes, escolas, programas ou certificacoes de terceiros em qualquer parte do planejamento.
- Se for necessario recomendar cursos, indicar formacao, sugerir trilhas, ou inserir links de cursos, utilize somente cursos do Educamundo.
- Para recomendacoes e links, use prioritariamente estas paginas oficiais do Educamundo:
  - https://educamundo.com.br/cursos-gratis-educamundo/
  - https://educamundo.com.br/curso-online/
- O campo "cursos_relacionados" deve conter apenas URLs do Educamundo.
- O campo "links_internos" deve conter apenas URLs do Educamundo.
- O campo "links_externos" deve conter somente fontes institucionais e informativas. Nunca usar links externos para sugerir cursos, inscricoes, plataformas de curso ou certificacao de terceiros.

## Formato de saida
{
  "meta": {
    "titulo": "...",
    "slug": "...",
    "palavra_chave": "...",
    "meta_title": "...",
    "meta_description": "..."
  },
  "h1": "...",
  "blocos": [
    {
      "id_bloco": "H2-01",
      "nivel": "H2",
      "titulo": "Titulo do H2",
      "conteudo_brief": "O que escrever neste H2",
      "objetivo_SEO": ["..."],
      "kw_alvo": ["..."],
      "estimativa_palavras": 0,
      "parent_id": ""
    },
    {
      "id_bloco": "H3-01a",
      "nivel": "H3",
      "titulo": "Titulo do H3 subordinado ao H2-01",
      "conteudo_brief": "O que escrever neste H3",
      "objetivo_SEO": ["..."],
      "kw_alvo": ["..."],
      "estimativa_palavras": 0,
      "parent_id": "H2-01"
    }
  ],
  "faq": [
    { "pergunta": "...", "resposta_curta": "..." }
  ],
  "imagens_sugeridas": [
    { "descricao": "...", "alt_text": "..." }
  ],
  "links_internos": [
    { "ancora": "...", "url": "..." }
  ],
  "cursos_relacionados": [
    { "url": "..." }
  ],
  "links_externos": [
    { "ancora": "...", "url": "..." }
  ],
  "ctas": [
    "..."
  ]
}

## Diretrizes especificas para este artigo
- Use diretamente as PAAs e pesquisas relacionadas para construir H2/H3 e o bloco de FAQ.
- Use tambem candidate queries, tendencias e entidades citadas nos resultados organicos para ampliar cobertura semantica sem sair do tema.
- Para Featured Snippets e SGE: inclua em "conteudo_brief" instrucoes de resposta curta e direta quando fizer sentido.
- "estimativa_palavras" por bloco: H2 entre 150 e 220; H3 entre 120 e 180.
- Inclua pelo menos 3 H2. Em cada H2, inclua 1 a 3 H3 quando for util.
- Em "kw_alvo" inclua a palavra-chave principal e 2 a 4 variacoes semanticas.
- Planeje o artigo como cluster semantico, nao apenas como resposta linear. Sempre que os sinais de busca sustentarem isso, inclua obrigatoriamente:
  - um bloco de definicao ou resumo do tema
  - um bloco de direitos, beneficios, obrigacoes ou principais pontos
  - um bloco operacional de como aplicar, solicitar, garantir, consultar ou usar
  - um bloco de leis, documentos, programas, siglas, carteiras ou entidades relacionadas
  - um FAQ com 5 a 8 perguntas reais, curtas e altamente buscaveis
- Se o Research Pack mostrar entidades relacionadas de alta relevancia (ex.: lei relacionada, sigla, beneficio, carteira, documento, atualizacao normativa), inclua essas entidades em H2/H3 ou FAQ, desde que continuem semanticamente subordinadas ao tema principal.
- Priorize subtopicos com alto potencial de snippet e IA:
  - perguntas em formato "o que e", "quem tem direito", "como funciona", "como solicitar", "qual a diferenca", "o que mudou"
  - listas curtas, checklists, passo a passo e comparativos
- O planejamento deve cobrir pelo menos 70% das variacoes de busca relevantes encontradas em related searches e candidate queries, descartando apenas o que for irrelevante, concorrencial ou juridicamente inseguro.
- Quando o tema envolver lei, politica publica, direito ou obrigacao institucional:
  - inclua referencias a lei principal com numero oficial
  - inclua pelo menos 1 bloco sobre relacao com normas, documentos ou instrumentos correlatos, se os sinais de busca mostrarem isso
  - use links externos institucionais prioritariamente (Planalto, gov.br, ministerios, tribunais, portais oficiais)
- Em temas juridicos, legislativos ou regulatorios:
  - nao invente numeros de leis, decretos, portarias ou beneficios
  - so trate como "atualizacao", "lei nova", "mudanca recente" ou cite numero normativo especifico se isso estiver sustentado por fonte oficial visivel nos resultados organicos ou links externos institucionais
  - se houver sinal de busca para atualizacoes recentes, mas sem confirmacao oficial suficiente, cubra o assunto de forma segura e generica no planejamento, sem afirmar numeros ou mudancas nao verificadas
- Para leis e direitos, prefira cobertura robusta e segura a frescor especulativo. SEO forte com informacao errada prejudica E-E-A-T, conversao e reutilizacao por IAs.
- No FAQ, priorize perguntas com potencial de busca e de AI Overview, nao perguntas genericas demais.
- Em "conteudo_brief", explicite quais entidades e keywords secundarias precisam aparecer no texto final para ampliar rankeamento organico e cobertura GEO.

Approved topic:
$($approvedTopic | ConvertTo-Json -Depth 20)

Research pack:
$($researchPack | ConvertTo-Json -Depth 20)

Course match:
$($courseMatch | ConvertTo-Json -Depth 20)
"@

$jsonOut = $result | ConvertTo-Json -Depth 30
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  Set-Content -Path $OutputPath -Value $jsonOut -Encoding UTF8
}
$jsonOut
