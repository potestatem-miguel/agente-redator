---
name: seo-title-slug
description: Gera titulo, slug, palavra_chave final e canonical_topic a partir de pesquisa aprovada. Use quando um agente precisar chamar a OpenAI para definir o alvo SEO principal antes da checagem de duplicidade e do planejamento.
---

# SEO Title Slug

Transforme um tema aprovado em alvo SEO publicavel.

## Dependencias de runtime

- `OPENAI_API_KEY`

## Ferramenta principal

Executar [run_seo_title_slug.ps1](scripts/run_seo_title_slug.ps1) quando esta etapa precisar rodar de forma operacional.

Exemplo:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\seo-title-slug\scripts\run_seo_title_slug.ps1 `
  -TemaOriginal "atividade dia da escola para educação infantil" `
  -ResearchPackPath ".\tmp\research-pack.json" `
  -ValidationPath ".\tmp\topic-validation.json"
```

## Procedimento

1. Escolher a palavra-chave principal mais forte do contexto.
2. Criar titulo com foco em CTR sem sacrificar clareza.
3. Gerar slug curto, estavel e amigavel.
4. Determinar `canonical_topic` para comparacao e catalogacao.

## Regras

- `titulo` com preferencia por ate 60 caracteres.
- Comecar pelo nucleo semantico mais forte sempre que isso nao soar artificial.
- `slug` em minusculas, sem acento, com hifens, idealmente 3 a 7 palavras.
- `canonical_topic` deve ser mais estavel que o titulo.
- Nao repetir formula clickbait vazia.

## Saida

Gerar exatamente o contrato de [approved-topic.schema.json](../../schemas/approved-topic.schema.json).
