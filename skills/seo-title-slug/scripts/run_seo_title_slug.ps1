param(
  [Parameter(Mandatory = $true)]
  [string]$TemaOriginal,

  [Parameter(Mandatory = $true)]
  [string]$ResearchPackPath,

  [Parameter(Mandatory = $true)]
  [string]$ValidationPath,

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
      return ($trimmed.Substring($first, $last - $first + 1) | ConvertFrom-Json)
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
      temperature = 0.3
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
    temperature = 0.3
  }

  $json = $body | ConvertTo-Json -Depth 30 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $response = Invoke-RestMethod -Method Post -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -Body $bytes -ContentType "application/json; charset=utf-8"
  return ($response.choices[0].message.content | ConvertFrom-Json)
}

$researchPack = Get-Content $ResearchPackPath -Raw | ConvertFrom-Json
$validation = Get-Content $ValidationPath -Raw | ConvertFrom-Json

$result = Invoke-LlmJson `
  -SystemPrompt "Voce gera titulo, slug, palavra_chave final e canonical_topic para artigos SEO. Responda apenas JSON valido." `
  -Provider "openai" `
  -UserPrompt @"
Retorne exatamente as chaves:
- tema_original
- titulo
- slug
- palavra_chave
- canonical_topic
- angulo_editorial

Regras:
- titulo com preferencia por ate 60 caracteres
- slug curto, em minusculas, sem acentos e com hifens
- canonical_topic mais estavel que o titulo
- evitar clickbait vazio
- preservar foco editorial brasileiro
- respeitar o tema aprovado e o angulo refinado da validacao
- se existir "refined_angle", ele deve guiar o recorte final sem abandonar a intencao central de busca
- nao simplifique o assunto a ponto de perder o recorte principal
- nao introduza outras datas comemorativas, campanhas ou pautas paralelas
- "titulo" deve refletir o tema final do artigo, nao apenas a keyword
- "palavra_chave" deve ser natural, legivel, coerente com o titulo e preferencialmente manter a keyword-raiz ou a forma mais buscavel do tema
- "canonical_topic" deve permanecer dentro do recorte aprovado, mas ser amplo o bastante para cobrir variacoes semanticas importantes
- preserve no titulo o termo principal de busca na forma exata ou muito proxima quando isso nao comprometer a naturalidade
- quando houver conflito entre tema amplo e angulo operacional, resolva assim:
  1. mantenha a keyword-raiz no titulo e na palavra_chave
  2. use o angulo editorial como complemento, subtese ou promessa pratica
  3. evite transformar uma busca ampla em long tail estreita demais
- priorize titulos com potencial de CTR e reaproveitamento por Google, AI Overviews e respostas de IA
- considere sinais do Research Pack para decidir se o usuario quer:
  - guia geral / resumo
  - direitos / principais pontos
  - passo a passo / como fazer
  - atualizacoes / leis relacionadas
- se houver entidades fortemente associadas no Research Pack (ex.: leis relacionadas, siglas, carteiras, beneficios, documentos, programas), preserve espaco semantico para elas no artigo final, sem tirar o foco do tema principal

Tema original:
$TemaOriginal

Validation:
$($validation | ConvertTo-Json -Depth 20)

Research pack:
$($researchPack | ConvertTo-Json -Depth 20)
"@

$jsonOut = $result | ConvertTo-Json -Depth 20
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  Set-Content -Path $OutputPath -Value $jsonOut -Encoding UTF8
}
$jsonOut
