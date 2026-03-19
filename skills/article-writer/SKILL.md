---
name: article-writer
description: Escreve blocos do artigo em HTML ou Markdown a partir do planejamento aprovado. Use quando um agente redator receber uma distribuicao de blocos e precisar produzir texto final sem alterar a estrutura editorial.
---

# Article Writer

Escreva apenas os blocos recebidos.

## Procedimento

1. Respeitar `titulo`, `nivel`, `parent_id`, `conteudo_brief` e `estimativa_palavras`.
2. Escrever em HTML simples com foco em legibilidade.
3. Abrir cada secao com resposta clara e direta quando houver potencial de snippet.
4. Inserir listas quando o bloco pedir passo a passo, checklist ou comparacao.

## Regras

- Nao criar, remover ou reordenar titulos.
- Nao escrever introducao ou conclusao globais, exceto se os blocos recebidos pedirem isso.
- Manter linguagem brasileira, humana e didatica.
- Usar apenas tags permitidas pelo sistema editorial.
- Inserir links do Educamundo somente quando previstos no planejamento.

## Saida

Gerar exatamente o contrato de [article-draft-parts.schema.json](../../schemas/article-draft-parts.schema.json).
