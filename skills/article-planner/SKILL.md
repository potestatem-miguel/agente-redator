---
name: article-planner
description: Gera o planejamento mestre do artigo em JSON com meta, H1, blocos H2/H3, FAQ, imagens sugeridas, links e CTAs. Use quando um agente precisar chamar a OpenAI para transformar um tema aprovado em article_plan.json pronto para distribuicao e redacao.
---

# Article Planner

Produza o `article_plan.json` completo.

## Dependencias de runtime

- `OPENAI_API_KEY`

## Ferramenta principal

Executar [run_article_planner.ps1](scripts/run_article_planner.ps1) quando esta etapa precisar rodar de forma operacional.

Exemplo:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\article-planner\scripts\run_article_planner.ps1 `
  -ApprovedTopicPath ".\tmp\approved-topic.json" `
  -ResearchPackPath ".\tmp\research-pack.json" `
  -CourseMatchPath ".\tmp\course-match.json"
```

## Entrada

- `approved_topic`
- `research_pack`
- `course_match`
- `editorial_context`

## Procedimento

1. Criar `meta_title`, `meta_description` e `h1`.
2. Organizar o artigo em H2 e H3 hierarquicos.
3. Usar PAA e pesquisas relacionadas para compor blocos e FAQ.
4. Definir `conteudo_brief`, `objetivo_seo`, `kw_alvo` e `estimativa_palavras` por bloco.
5. Sugerir imagens, links internos, links externos institucionais e CTAs.

## Regras

- Minimo de 3 H2.
- Cada bloco deve ser funcional para redacao paralela.
- `conteudo_brief` precisa orientar sem escrever o texto final.
- `links_externos` apenas institucionais e informativos.
- Preservar foco em SEO, AEO e GEO.

## Saida

Gerar exatamente o contrato de [article-plan.schema.json](../../schemas/article-plan.schema.json).
