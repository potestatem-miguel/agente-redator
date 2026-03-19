# Article Orchestrator API

API HTTP para gerar artigos via `article-orchestrator`, pronta para deploy em GitHub + EasyPanel e consumo pelo n8n.

## Endpoints

### `GET /health`
Retorna status da API.

### `POST /run-article`
Body JSON:

```json
{
  "tema": "lei berenice piana",
  "stop_after_planning": false
}
```

Resposta imediata:
- `status = "queued"`
- `job_id = "..."`

### `GET /job-status?id=...`
Consulta o status do job.

### `GET /job-result?id=...`
Retorna o resultado final quando o job estiver concluido.

## Variaveis de ambiente

Use o arquivo `.env.example` como base:

- `SERPAPI_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `ANTHROPIC_MODEL`
- `OPENAI_MODEL`

## Provedores por etapa

O fluxo atual usa modelo hibrido:

- OpenAI:
  - `topic-validation`
  - `seo-title-slug`
  - `distribuidor`
  - `image-package`
- Anthropic:
  - `article-planner`
  - `repair-article-plan`
  - `writer 1`
  - `writer 2`
  - `writer 3`
  - `writer final`

## Rodar localmente

```powershell
pwsh -NoProfile -File .\server.ps1 -Port 8080
```

Teste rapido:

```powershell
Invoke-RestMethod -Method Get -Uri "http://localhost:8080/health"
```

```powershell
$body = @{
  tema = "lei berenice piana"
  stop_after_planning = $false
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "http://localhost:8080/run-article" `
  -ContentType "application/json" `
  -Body $body
```

Depois:

```powershell
Invoke-RestMethod -Method Get -Uri "http://localhost:8080/job-status?id=SEU_JOB_ID"
Invoke-RestMethod -Method Get -Uri "http://localhost:8080/job-result?id=SEU_JOB_ID"
```

## Deploy no EasyPanel

1. Suba este projeto para um repositorio no GitHub.
2. No EasyPanel, crie um app via `Dockerfile`.
3. Configure a porta `8080`.
4. Defina as variaveis de ambiente do `.env.example`.
5. Publique o app.
6. Use a URL publica do EasyPanel no node `HTTP Request` do n8n.

## Integracao com n8n

### Planejamento apenas

1. POST para `/run-article`:

```json
{
  "tema": "lei berenice piana",
  "stop_after_planning": true
}
```

2. Consultar `/job-status?id=...`
3. Buscar `/job-result?id=...`

### Artigo completo

1. POST para `/run-article`:

```json
{
  "tema": "lei berenice piana",
  "stop_after_planning": false
}
```

2. Consultar `/job-status?id=...`
3. Buscar `/job-result?id=...`

No resultado final, o n8n deve consumir:

- `result.wordpress` para publicar no WordPress
- `result.media.image_package` para gerar e enviar imagem
- `result.database` para persistencia

## Observacoes

- Os artefatos de cada execucao sao salvos em `test-output/`.
- O servidor retorna JSON pronto para o n8n, sem necessidade de adaptar caminhos locais.
