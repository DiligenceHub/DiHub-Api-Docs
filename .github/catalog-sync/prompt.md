# Sincronização do catálogo: doc + core-api

Você roda no GitHub Actions, sem ninguém olhando. Seu trabalho é **abrir ou atualizar PRs-lembrete**. Nunca faça merge e nunca faça push em `main` ou `develop`.

## Arquivos no workspace

| Caminho | O que é |
|---|---|
| `catalog.json` | Catálogo de prod (Lambda `catalogExport`): `states` (UF → comarcas ativas), `packages` (escopo → certidões `{code, name, issuer}` na ordem canônica), `statesWithoutScope` |
| `trigger.txt` | O que disparou esta rodada |
| `hydrogen.diff` | Diff do merge no hydrogen que disparou (vazio em rodada agendada ou manual) |
| `api-docs/` | Repo da doc (`main`). Leia `api-docs/CLAUDE.md` antes de editar: as regras de conteúdo valem |
| `hydrogen/` | hydrogen na `main` |
| `core-api/` | core-api na `develop` |

`gh` e `git` já estão autenticados (`GH_TOKEN`). Configure o autor dos commits com `git config user.name "dihub-catalog-bot"` e `git config user.email "catalog-bot@dihub.com.br"` em cada repo antes de commitar. Commits sem `Co-Authored-By`.

## Tarefa 1: doc × catálogo de prod

Compare a doc com `catalog.json`:

- `api-docs/reference/todas-certidoes.mdx`: um accordion por UF de `states`; as tabelas de cada UF batem com `packages.ESTADUAL_<UF>_CPF` e `ESTADUAL_<UF>_CNPJ` (certidão + emissor, na ordem do JSON); as federais batem com `FEDERAL_CPF`/`FEDERAL_CNPJ`; a tabela de municipais bate com os pacotes `MUNICIPAL_*` cuja comarca está ativa; a seção Emissores lista todos os emissores usados.
- O exemplo de resposta de `/diligences/districts` (`api-reference/diligences/districts.mdx` e o exemplo no `openapi.json`) traz só comarcas que existem em `states`.

Se houver diferença:

1. Branch `automation/catalog-sync` a partir de `origin/main` do api-docs. Se já existir PR aberto dessa branch, atualize a mesma branch e o mesmo PR. Não abra outro.
2. Edite só o necessário para a doc refletir prod. Não mexa em texto que não tem relação com a diferença.
3. Valide: `python3 -c "import json;json.load(open('openapi.json'))"`.
4. PR para `main`, título `docs(catálogo): <resumo>`. Corpo: o que mudou e a origem de cada mudança no `catalog.json`.
5. Se alguma UF que você está adicionando estiver em `statesWithoutScope`, abra como **draft** e explique: a API dá 500 nessa UF até a core-api ter o escopo. Senão, abra normal (pronto para review).

## Tarefa 2: core-api × hydrogen

A core-api tem cópias do catálogo do hydrogen:

| hydrogen | core-api |
|---|---|
| `src/libs/commom/enums/emitDiligence.enum.ts` (`CertificateScope`) | `src/enums/emission.enum.ts` (`CertificateScope`) |
| `src/libs/commom/consts/orderOfArrangementOfCertificates.ts` (`certificateOrder`, `orderedIssuer`) | `src/consts/certificateOrder.consts.ts` (`CERTIFICATE_ORDER`, `ORDERED_ISSUERS`) |

Compare as entradas, não a formatação. Se faltar algo na core-api:

1. Branch `automation/core-api-catalog-sync` a partir de `origin/develop` da core-api. Mesma regra de reaproveitar PR aberto.
2. Porte as entradas que faltam **na mesma posição relativa** em que estão no hydrogen. Nunca coloque no fim do array.
3. Para cada `ESTADUAL_<UF>_*` novo, adicione um teste em `src/routes/diligences/helpers/__tests__/emission.helper.spec.ts` seguindo o padrão do bloco `PI/PA` que já existe.
4. PR para `develop` como **draft** (é código gerado, precisa de revisão). Título `feat(catálogo): <resumo>`.
5. Se `statesWithoutScope` não estiver vazio, comece o título com `[URGENTE]` e diga no corpo: essas UFs estão vendidas em prod e a API devolve 500 nelas.

## Para os dois PRs

- Se os dois forem abertos, cite um no corpo do outro.
- Se `hydrogen.diff` não estiver vazio, link o commit do hydrogen e diga o que do diff ainda não está em prod (está no diff mas não no `catalog.json`). Isso fica como lembrete no corpo do PR da doc. Se não houver diferença de doc, mas o diff trouxer mudança que ainda não chegou em prod, abra o PR da doc como **draft** com um commit vazio (`git commit --allow-empty`) e o lembrete no corpo.
- Não invente certidão, emissor ou regra. A fonte é o `catalog.json` e o código dos repos.
- Se não houver diferença em nenhuma das tarefas, não abra nada. Termine dizendo que está tudo em dia.
