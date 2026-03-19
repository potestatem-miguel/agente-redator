---
name: topic-validation
description: Valida se um tema e suas consultas derivadas servem para servidor publico, utilidade editorial e intencao de busca. Use quando um agente precisar aprovar, reprovar ou refinar um tema antes do planejamento do artigo.
---

# Topic Validation

Avalie um `research_pack` e devolva uma decisao editorial objetiva.

## Objetivo

Separar tema util de ruido, modismo vazio, consulta comercial irrelevante ou assunto fraco para o publico de servidor publico.

## Procedimento

1. Verificar aderencia ao publico de servidor publico.
2. Medir utilidade pratica, perenidade e potencial de busca.
3. Penalizar modismos, fofoca, celebridade, politica partidaria momentanea e temas sem aplicacao formativa.
4. Identificar angulos fortes quando o tema bruto estiver bom, mas mal formulado.
5. Devolver uma de tres decisoes: `approved`, `refine`, `rejected`.

## Criterios

- `aderencia_publico`
- `utilidade_pratica`
- `potencial_busca`
- `perenidade`
- `risco_irrelevancia`
- `risco_obsolescencia`

## Regras

- Aprovar apenas quando houver relacao clara com carreira, rotina, direitos, formacao, gestao, educacao, saude, legislacao, atendimento publico ou desenvolvimento profissional.
- Se o tema for aproveitavel com ajuste, preferir `refine` a `rejected`.
- Explicar a decisao com justificativas curtas e acionaveis.

## Saida

Gerar exatamente o contrato de [topic-validation.schema.json](../../schemas/topic-validation.schema.json).
