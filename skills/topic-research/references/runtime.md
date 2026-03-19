# Runtime

Este skill foi convertido para pesquisa live.

## Variavel esperada

- `SERPAPI_API_KEY`

## Endpoints usados

- `engine=google`
- `engine=google_trends`

## Comportamento

- usa Google Brasil com `gl=br`, `hl=pt-br`, `google_domain=google.com.br`
- tenta Trends com `geo=BR`, `data_type=RELATED_QUERIES`, `date=today 1-m`
- se Trends falhar, continua com Search
- se Search falhar, retorna erro
