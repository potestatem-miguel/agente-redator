# Runtime

Este skill foi convertido para usar consulta real no Supabase.

## Variaveis esperadas

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`

## RPC usado

- `match_cursos`

## Comportamento

- gera embedding da `palavra_chave`
- consulta cursos semanticamente proximos
- deduplica por `slug`, `id` ou `link`
- retorna ate 2 cursos finais no pacote

## Observacao

`internal_links` ainda depende de uma fonte adicional. Se ela nao existir no runtime, o skill retorna lista vazia de forma explicita.
