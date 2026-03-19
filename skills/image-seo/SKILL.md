---
name: image-seo
description: Cria o pacote textual da imagem do artigo com prompt, alt text, titulo, caption, nome de arquivo e instrucoes SEO. Use quando um agente precisar pensar a imagem, mas a renderizacao final ficar a cargo do n8n ou de outro provedor.
---

# Image SEO

Crie apenas o pacote textual da imagem. Nao renderize a imagem.

## Procedimento

1. Ler `article_final`.
2. Escolher um conceito visual fiel ao nucleo do artigo.
3. Gerar `prompt_imagem` detalhado, sem depender de contexto oculto.
4. Gerar `alt_text`, `title`, `caption` e `nome_arquivo`.
5. Registrar orientacoes para thumbnail, destaque e enquadramento.

## Regras

- Nao solicitar a geracao da imagem dentro do agente.
- Evitar texto legivel dentro da imagem, salvo exigencia futura.
- O `alt_text` deve descrever o que a imagem mostra, nao repetir mecanicamente o titulo.
- `nome_arquivo` deve ser SEO friendly.

## Saida

Gerar exatamente o contrato de [image-package.schema.json](../../schemas/image-package.schema.json).
