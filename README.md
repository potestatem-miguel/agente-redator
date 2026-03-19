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

Resposta:
- `mode = "planning"` quando `stop_after_planning = true`
- `mode = "full"` quando a execucao completa chega ao `publish-package.json`

## Variaveis de ambiente

Use o arquivo `.env.example` como base:

- `SERPAPI_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `LLM_PROVIDER`
- `ANTHROPIC_MODEL`
- `OPENAI_MODEL`

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

## Deploy no EasyPanel

1. Suba este projeto para um repositorio no GitHub.
2. No EasyPanel, crie um app via `Dockerfile`.
3. Configure a porta `8080`.
4. Defina as variaveis de ambiente do `.env.example`.
5. Publique o app.
6. Use a URL publica do EasyPanel no node `HTTP Request` do n8n.

## Integracao com n8n

### Planejamento apenas

POST para `/run-article`:

```json
{
  "tema": "lei berenice piana",
  "stop_after_planning": true
}
```

### Artigo completo

POST para `/run-article`:

```json
{
  "tema": "lei berenice piana",
  "stop_after_planning": false
}
```

O n8n deve consumir o campo:

- `result.wordpress` para publicar no WordPress
- `result.media.image_package` para gerar e enviar imagem
- `result.database` para persistencia

## Observacoes

- Os artefatos de cada execucao sao salvos em `test-output/`.
- O servidor retorna JSON pronto para o n8n, sem necessidade de adaptar caminhos locais.
