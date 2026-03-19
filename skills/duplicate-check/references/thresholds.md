# Thresholds

Sugestao operacional:

- `duplicate_exact`: slug identico
- `duplicate_semantic`: score >= 0.80
- `related`: 0.65 a 0.79
- `unique`: abaixo disso

Ajuste o threshold no codigo, nao no texto livre do agente.

Endpoints usados no fluxo atual:

- `POST {SUPABASE_URL}/rest/v1/rpc/check_slugs`
- `POST {SUPABASE_URL}/rest/v1/rpc/find_similar_titles`

Modelo de embedding usado no fluxo atual:

- `text-embedding-3-small`
