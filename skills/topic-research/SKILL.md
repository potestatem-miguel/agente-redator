---
name: topic-research
description: Pesquisa SERP, Google Trends, PAA, resultados organicos e related searches para abastecer a esteira de criacao de artigos. Use quando um agente precisar consultar o SerpApi e transformar um tema em research_pack.json estruturado para SEO, AEO e GEO.
---

# Topic Research

Produza `research_pack.json` a partir de um `tema` e, quando existir, de um `job_context`.

## Dependencias de runtime

- `SERPAPI_API_KEY`

## Ferramenta principal

Executar [run_topic_research.ps1](scripts/run_topic_research.ps1) sempre que a pesquisa precisar ser live.

Exemplo:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\topic-research\scripts\run_topic_research.ps1 `
  -Tema "atividade dia da escola para educação infantil"
```

## Entrada minima

- `tema`
- `locale` default `pt-BR`
- `pais` default `BR`
- `janela_tempo` default `30d`
- `fontes` disponiveis no job

## Procedimento

1. Consolidar o tema base e as variacoes obvias de busca.
2. Ler sinais reais de Google Search, related searches, PAA e organic results.
3. Tentar complementar com Google Trends `RELATED_QUERIES`.
4. Extrair somente sinais uteis para decisao editorial.
5. Remover ruido, duplicatas e termos desconectados do tema.
6. Classificar cada query por intencao: `informacional`, `transacional`, `navegacional`, `mista`.
7. Destacar oportunidades para featured snippet, FAQ e clusters semanticos.
8. Devolver apenas fatos observados e inferencias curtas marcadas como inferencia.

## Regras

- Priorizar buscas brasileiras e linguagem de servidor publico quando houver sinais claros.
- Nao escrever artigo, nao sugerir estrutura final e nao tomar decisao de aprovacao.
- Nao inventar metricas. Se faltar dado, retornar `null` ou lista vazia.
- Manter a saida enxuta e util para as proximas etapas.
- Se Google Trends falhar, ainda retornar resultado com base no Google Search e marcar `missing_sources`.

## Saida

Gerar exatamente o contrato de [research-pack.schema.json](../../schemas/research-pack.schema.json).

## Falha

- Se o tema for ambiguo, retornar `status: "needs_clarification"` com `ambiguidades`.
- Se as fontes estiverem incompletas, retornar `status: "partial"` e listar lacunas em `missing_sources`.
- Se o SerpApi falhar completamente, retornar erro estruturado e nunca fingir `status: "ok"`.
