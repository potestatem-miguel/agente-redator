# Runtime

Este skill foi convertido de protocolo para skill operacional.

## Variaveis esperadas

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`

## RPCs usados

- `check_slugs`
- `find_similar_titles`

## Comportamento

- slug exato bloqueia imediatamente
- score >= 0.80 retorna `duplicate_semantic`
- score entre 0.65 e 0.79 retorna `related`
- abaixo disso retorna `unique`

## Observacao

Se voce preferir, o agente pode usar este skill via script local e o n8n fica apenas como orquestrador externo.
