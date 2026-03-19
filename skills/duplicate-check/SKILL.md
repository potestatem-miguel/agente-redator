---
name: duplicate-check
description: Executa a checagem de duplicidade exata e semantica contra o catalogo de artigos no Supabase. Use quando um agente precisar consultar o Supabase, verificar slug, gerar embedding do titulo e decidir se o tema pode seguir, deve ser ajustado ou descartado por sobreposicao com conteudo existente.
---

# Duplicate Check

Este skill deve executar a verificacao real no Supabase seguindo o mesmo desenho do fluxo atual do n8n.

## Entrada

- `approved_topic.titulo`
- `approved_topic.slug`
- `approved_topic.palavra_chave`
- `approved_topic.canonical_topic`

## Dependencias de runtime

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`

## Ferramenta principal

Executar [check_duplicates.ps1](scripts/check_duplicates.ps1) sempre que a tarefa pedir validacao real.

Exemplo:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\duplicate-check\scripts\check_duplicates.ps1 `
  -Title "Lei de Diretrizes e Bases da Educacao" `
  -Slug "lei-de-diretrizes-e-bases-da-educacao" `
  -Keyword "ldb educacao"
```

## Procedimento

1. Consultar `rpc/check_slugs` para verificar colisao exata de `slug`.
2. Gerar embedding do `titulo` com `text-embedding-3-small`.
3. Consultar `rpc/find_similar_titles` com o embedding.
4. Classificar o caso em `unique`, `related`, `duplicate_exact`, `duplicate_semantic`.
5. Se houver relacao, sugerir angulo alternativo curto e acionavel.

## Regras

- Nao inventar score vetorial.
- Confiar primeiro no resultado dos endpoints do Supabase.
- Considerar `duplicate_exact` como bloqueio imediato.
- Considerar `duplicate_semantic` como bloqueio por padrao.
- Considerar `related` como sinal para refinar angulo, nao descartar automaticamente.
- Usar os thresholds padrao documentados em [thresholds.md](references/thresholds.md).

## Saida

Gerar exatamente o contrato de [duplicate-check.schema.json](../../schemas/duplicate-check.schema.json).

## Notas de implementacao

- O fluxo atual usa `check_slugs` para exato e `find_similar_titles` para semantico.
- O skill deve retornar o JSON do script sem reformatar campos importantes.
- Se a consulta externa falhar, retornar erro estruturado em vez de fingir `unique`.
