# DiHub API Docs

Documentação pública da API DiHub, publicada em https://docs.dihub.com.br (Mintlify).

## Rodar localmente

```bash
npm install
npm run dev
```

Preview em `http://localhost:3000`. Se o servidor não subir, atualize o CLI com `mint update`.

## Estrutura

- `docs.json`: navegação, tema e cores. Página nova só aparece depois de registrada em `navigation`.
- `index.mdx`, `introduction/`, `reference/`, `webhooks/`, `llms/`: aba **Guia**.
- `api-reference/`: aba **Referência da API**. Cada página aponta para um endpoint do `openapi.json` pelo campo `openapi` do frontmatter.
- `openapi.json`: especificação da API. A fonte da verdade é o código do `core-api` (branch `main`).
- `llms.txt`: índice para LLMs, escrito à mão. Substitui o gerado pelo Mintlify; atualize quando mudar página ou endpoint.

## Publicar

Merge na `main` publica automaticamente pelo app do Mintlify no GitHub.
