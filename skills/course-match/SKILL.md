---
name: course-match
description: Seleciona cursos do Educamundo e links internos coerentes com o tema aprovado. Use quando um agente precisar consultar o Supabase para encontrar cursos semanticamente proximos do tema e enriquecer o planejamento sem citar concorrentes.
---

# Course Match

Escolha cursos do Educamundo com consulta real ao Supabase.

## Dependencias de runtime

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `OPENAI_API_KEY`

## Ferramenta principal

Executar [match_courses.ps1](scripts/match_courses.ps1) sempre que a tarefa pedir selecao real de cursos.

Exemplo:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\course-match\scripts\match_courses.ps1 `
  -Keyword "gestao escolar" `
  -Title "Gestao escolar: o que faz e como melhorar processos"
```

## Procedimento

1. Ler `approved_topic`, `research_pack` e contexto editorial.
2. Gerar embedding a partir da palavra-chave principal; se faltar, usar o titulo.
3. Consultar `rpc/match_cursos` no Supabase.
4. Ordenar por score e deduplicar por slug ou link.
5. Selecionar ate 2 cursos mais coerentes.
6. Sugerir ancora natural para insercao no texto.

## Regras

- Nao citar cursos, plataformas ou certificacoes de terceiros.
- Priorizar URL oficial do Educamundo.
- Se nenhum curso for realmente aderente, retornar lista vazia.
- Os links internos devem apoiar o conteudo, nao competir com ele.
- Se a fonte real de links internos nao estiver disponivel, retornar `internal_links: []`.
- Nao inventar score.

## Saida

Gerar exatamente o contrato de [course-match.schema.json](../../schemas/course-match.schema.json).

## Notas de implementacao

- O fluxo atual usa embedding da palavra-chave e `rpc/match_cursos`.
- O resultado bruto costuma trazer `id`, `slug`, `link`, `title`, `score`.
- O skill deve devolver cursos ja ranqueados e prontos para consumo pelo planejador.
