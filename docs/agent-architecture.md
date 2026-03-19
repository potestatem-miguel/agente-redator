# Arquitetura

## Agentes

- `article-orchestrator`: coordena tudo.
- `research-agent`: usa `topic-research` e `topic-validation`.
- `planning-agent`: usa `seo-title-slug`, `duplicate-check`, `course-match`, `article-planner`.
- `writer-agent`: usa `article-writer` em paralelo.
- `final-editor-agent`: usa `article-finisher`, `image-seo`, `publishing-contract`.

## O que fica no n8n

- webhook de entrada
- fila
- retries
- timeouts
- chamadas de busca e embeddings
- consultas Supabase
- geracao real da imagem
- upload no WordPress
- persistencia e logs

## O que fica nas skills

- regra editorial
- criterio de decisao
- formato de saida
- contratos JSON
- checklists
