---
name: publishing-contract
description: Normaliza o pacote final para WordPress, banco de artigos e logs operacionais. Use quando um agente precisar devolver publish_package.json consistente para o n8n publicar e persistir os dados.
---

# Publishing Contract

Transforme os artefatos finais em um contrato consumivel pelo n8n.

## Entrada

- `approved_topic`
- `article_plan`
- `article_final`
- `image_package`
- `course_match`
- `job_context`

## Procedimento

1. Mapear campos obrigatorios para WordPress.
2. Mapear campos para banco e observabilidade.
3. Preservar ids, status e timestamps do job quando existirem.
4. Preparar um objeto unico para publicacao.

## Regras

- Nao publicar nada.
- Nao gerar side effects.
- Se faltar campo obrigatorio, retornar `ready_to_publish: false` com erros objetivos.

## Saida

Gerar exatamente o contrato de [publish-package.schema.json](../../schemas/publish-package.schema.json).
