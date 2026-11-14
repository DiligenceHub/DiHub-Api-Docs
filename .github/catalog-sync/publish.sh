#!/usr/bin/env bash
# Job publish (clean runner, the agent never ran here): decrypts the agent's
# output, validates it, copies it by fixed name into fresh checkouts, commits,
# pushes only to automation/* and opens or updates the PRs. PR titles and
# bodies come from the templates below; no free text from the agent.
#
# cwd: workspace with fresh checkouts in api-docs/ and core-api/.
# env: CS_PAT and GH_TOKEN (PAT), IN_DIR (artifact), CATALOG (catalog.json from
#      the catalog job), DRY_RUN, BEFORE, AFTER, RUN_URL, GIT_CONFIG_GLOBAL=/dev/null.
set -euo pipefail
export LC_ALL=C
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

state="$RUNNER_TEMP/catalog-sync"
plain="$state/plain"
base="$state/base"
umask 077
mkdir -p "$plain" "$base"
bot_name=dihub-catalog-bot
bot_email=catalog-bot@dihub.com.br

g() {
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
    -c user.name="$bot_name" -c user.email="$bot_email" "$@"
}
fail() { echo "::error::$*"; exit 1; }

# 1. Decrypt: fixed names only, regular files only. Nothing else in the artifact is read.
if [ -z "${CS_PAT:-}" ]; then fail "DOCS_AUTOMATION_TOKEN vazio"; fi
key=$(cs_derive_key)
echo "::add-mask::$key"
printf '%s' "$key" > "$state/key"
for f in "${CS_FILES[@]}"; do
  src="$IN_DIR/$(cs_flat "$f")"
  if [ -L "$src" ] || [ ! -f "$src" ]; then fail "artifact sem $f (ou não é arquivo regular)"; fi
  if ! cs_crypt dec "$state/key" "$src" "$plain/$(cs_flat "$f")" 2>/dev/null; then fail "artifact: $f não decifra"; fi
  if [ "$(wc -c < "$plain/$(cs_flat "$f")")" -gt "$CS_MAX_BYTES" ]; then fail "$f passa de $CS_MAX_BYTES bytes"; fi
done
rm -f "$state/key"
p() { printf '%s/%s' "$plain" "$(cs_flat "$1")"; }

# 2. result.json: the agent only answers one yes/no question.
result=$(p out/result.json)
if [ "$(wc -c < "$result")" -gt 1024 ] || ! jq -e \
  'type == "object" and (keys == ["hydrogenPending", "version"]) and .version == 1 and (.hydrogenPending | type == "boolean")' \
  "$result" >/dev/null 2>&1; then
  fail "out/result.json fora do schema (rodada incompleta)"
fi
pending=$(jq -r .hydrogenPending "$result")

# 3. No credential-looking string in anything that goes to a PR.
secret_re='sk-ant-|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY'
for f in "${CS_FILES[@]}"; do
  if grep -qE -- "$secret_re" "$(p "$f")"; then fail "$f contém algo com cara de credencial"; fi
done

# 4. Content: each changed line must look like what the agent is supposed to change.
# Only the line count goes to the log (public repo), never the content.
# added <file in checkout> -> $state/lines (lines the agent added). Exit 1 = differ; >1 = error.
added() {
  local rc=0
  g diff --no-index --no-color -U0 -- "$1" "$(p "$1")" > "$state/diff" || rc=$?
  if [ "$rc" -gt 1 ]; then fail "diff de $1 falhou"; fi
  awk '/^@@/ { h = 1; next } h && /^\+/ { print substr($0, 2) }' "$state/diff" > "$state/lines"
}
check_lines() { # check_lines <file> <jq regex> <max lines>
  local f=$1 re=$2 max=$3 bad
  added "$f"
  if [ "$(wc -l < "$state/lines")" -gt "$max" ]; then fail "$f: mais de $max linhas novas"; fi
  bad=$(jq -R -r --arg re "$re" 'select(test($re) | not)' "$state/lines" | wc -l | tr -d ' ')
  if [ "$bad" -gt 0 ]; then fail "$f: $bad linha(s) nova(s) fora do formato esperado"; fi
}
cell='[ \p{L}\p{N}ºª°.,;:()/&+'"'"'–—-]+'
check_lines api-docs/reference/todas-certidoes.mdx \
  '^$|^\|( *:?-+:? *\|)+$|^\|('"$cell"'\|)+$|^ *<Accordion title="[\p{L} ]+ \([A-Z]{2}\)">$|^ *</?Accordion(Group)?>$' 800
check_lines api-docs/api-reference/diligences/districts.mdx '^$|^ *"[A-Z]{2}": \[("[A-Z0-9_]+"(, )?)*\],?$' 100
if ! jq empty "$(p api-docs/openapi.json)" 2>/dev/null; then fail "api-docs/openapi.json não é JSON válido"; fi
# openapi.json: every changed leaf is a code (UF/comarca) under a key made of identifier characters.
if ! jq -n -e --slurpfile a api-docs/openapi.json --slurpfile b "$(p api-docs/openapi.json)" '
  $a[0] as $A | $b[0] as $B
  | [$B | paths(scalars) | . as $q | select(($A | try getpath($q) catch null) != ($B | getpath($q)))] as $changed
  | ($changed | length) <= 500
    and all($changed[]; . as $q
      | all($q[] | select(type == "string"); test("^[A-Za-z0-9_./{}-]{1,80}$"))
      and ($B | getpath($q) | type == "string" and test("^[A-Z0-9_]{1,60}$")))' >/dev/null; then
  fail "api-docs/openapi.json: mudança fora de código de UF/comarca"
fi
code_re='child_process|process\.env|eval\(|Function\(|require\(|import\(|https?://|fetch\(|exec(Sync)?\('
for f in core-api/src/enums/emission.enum.ts core-api/src/consts/certificateOrder.consts.ts \
  core-api/src/routes/diligences/helpers/__tests__/emission.helper.spec.ts; do
  added "$f"
  if [ "$(wc -l < "$state/lines")" -gt 800 ]; then fail "$f: mais de 800 linhas novas"; fi
  if grep -qE -- "$code_re" "$state/lines"; then fail "$f: linha nova com chamada fora do esperado para enum/const/teste"; fi
done

# 5. Copy by fixed name onto the fresh checkouts (regular files only).
for f in "${CS_FILES[@]}"; do
  if [ "$f" = out/result.json ]; then continue; fi
  if ! cs_regular "$f"; then fail "$f não é arquivo regular no checkout"; fi
  cp -- "$f" "$base/$(cs_flat "$f")"
  cp -- "$(p "$f")" "$f"
done

# Sanity: nothing but the allowlist changed (NUL-safe).
check_paths() {
  local dir=$1 entry path ok allowed; shift
  while IFS= read -r -d '' entry; do
    path=${entry:3}
    ok=false
    for allowed in "$@"; do if [ "$path" = "$allowed" ]; then ok=true; fi; done
    if [ "$ok" != true ]; then fail "$dir: alteração fora do permitido"; fi
  done < <(g -C "$dir" status --porcelain=v1 -z --no-renames --untracked-files=all)
}
check_paths api-docs reference/todas-certidoes.mdx api-reference/diligences/districts.mdx openapi.json
check_paths core-api src/enums/emission.enum.ts src/consts/certificateOrder.consts.ts \
  src/routes/diligences/helpers/__tests__/emission.helper.spec.ts

# 6. Facts for the templates, computed here (never taken from the agent).
ufs() { grep -oE '<Accordion title="[^"]*\(([A-Z]{2})\)">' "$1" | grep -oE '\([A-Z]{2}\)' | tr -d '()' | sort -u || true; }
ufs "$base/$(cs_flat api-docs/reference/todas-certidoes.mdx)" > "$state/ufs-before"
ufs api-docs/reference/todas-certidoes.mdx > "$state/ufs-after"
removed=$(comm -23 "$state/ufs-before" "$state/ufs-after" | paste -sd, -)
comm -13 "$state/ufs-before" "$state/ufs-after" > "$state/ufs-added"
added_ufs=$(paste -sd, - < "$state/ufs-added")
jq -r '.statesWithoutScope // [] | .[] | select(type == "string" and test("^[A-Z]{2}$"))' "$CATALOG" | sort -u > "$state/unscoped"
unscoped=$(paste -sd, - < "$state/unscoped")
added_unscoped=$(comm -12 "$state/ufs-added" "$state/unscoped" | paste -sd, -)
# Public doc PR gets only the event name; hydrogen SHAs go only to the private core-api PR.
doc_trigger="evento \`${GITHUB_EVENT_NAME:-?}\`"
trigger=$doc_trigger
sha_re='^[0-9a-f]{40}$'
if [[ "${BEFORE:-}" =~ $sha_re && "${AFTER:-}" =~ $sha_re ]]; then
  trigger="merge no hydrogen \`${BEFORE:0:12}..${AFTER:0:12}\`"
fi
pending_line="Há mudança de catálogo no hydrogen que ainda não chegou em prod."

doc_changed=false
if ! g -C api-docs diff --quiet; then doc_changed=true; fi
core_changed=false
if ! g -C core-api diff --quiet; then core_changed=true; fi

# 7. Commit + push only to automation/* + idempotent PR.
# publish <dir> <repo> <base> <branch> <draft> <allow_empty> <title> <body file>
publish() {
  local dir=$1 repo=$2 base_ref=$3 branch=$4 draft=$5 allow_empty=$6 title=$7 body=$8
  local remote_sha foreign pr number is_draft
  case "$branch" in automation/*) ;; *) fail "branch fora de automation/*: $branch" ;; esac

  g -C "$dir" switch --quiet -c "$branch"
  g -C "$dir" add -A
  if g -C "$dir" diff --cached --quiet; then
    if [ "$allow_empty" != true ]; then
      echo "$repo: sem diferença, nada a abrir."
      return 0
    fi
    g -C "$dir" commit --quiet --allow-empty -m "$title"
  else
    g -C "$dir" commit --quiet -m "$title"
  fi

  remote_sha=$(g -C "$dir" ls-remote --heads origin "refs/heads/$branch" | cut -f1)
  if [ -n "$remote_sha" ]; then
    g -C "$dir" fetch --quiet --no-tags origin "refs/heads/$branch"
    foreign=$(g -C "$dir" log --format=%ae "$remote_sha" --not "origin/$base_ref" | grep -vxF "$bot_email" || true)
    if [ -n "$foreign" ]; then
      fail "$repo: $branch tem commit que não é do bot. Mergeie ou feche o PR e apague a branch."
    fi
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] $repo: push em $branch, PR para $base_ref (draft=$draft): $title"
    g -C "$dir" show --stat --format=%s HEAD
    return 0
  fi

  g -C "$dir" push --quiet --force-with-lease="refs/heads/$branch:$remote_sha" origin "HEAD:refs/heads/$branch"

  pr=$(gh pr list -R "$repo" --head "$branch" --base "$base_ref" --state open --json number,isDraft,url -q '.[0] // empty')
  if [ -n "$pr" ]; then
    number=$(jq -r .number <<< "$pr")
    is_draft=$(jq -r .isDraft <<< "$pr")
    gh pr edit "$number" -R "$repo" --title "$title" --body-file "$body" >/dev/null
    if [ "$draft" = true ] && [ "$is_draft" != true ]; then
      gh pr ready "$number" -R "$repo" --undo >/dev/null
    fi
    jq -r .url <<< "$pr" > "$state/${branch#automation/}.url"
  else
    local flags=()
    if [ "$draft" = true ]; then flags+=(--draft); fi
    gh pr create -R "$repo" --base "$base_ref" --head "$branch" --title "$title" --body-file "$body" "${flags[@]}" > "$state/${branch#automation/}.url"
  fi
  echo "$repo: $(cat "$state/${branch#automation/}.url")"
}

# Doc (public repo): only computed facts and lines already validated above.
# Draft if a UF leaves the doc, if a new UF has no scope in core-api, or if it is only the reminder.
if [ "$doc_changed" = true ] || [ "$pending" = true ]; then
  draft=false
  if [ -n "$removed" ] || [ -n "$added_unscoped" ]; then draft=true; fi
  if [ "$doc_changed" != true ]; then draft=true; fi
  rows_file="$state/rows"
  g diff --no-index --no-color -U0 -- "$base/$(cs_flat api-docs/reference/todas-certidoes.mdx)" api-docs/reference/todas-certidoes.mdx \
    | awk '/^@@/ { h = 1; next } h && /^[+-]\|/ && !/^[+-]\|[ :|-]+$/' > "$rows_file" || true
  {
    echo "## Doc × catálogo de prod"
    echo
    echo "PR-lembrete do workflow \`catalog-sync\` ([run]($RUN_URL)). Disparo: $doc_trigger. Texto montado pelo workflow a partir dos arquivos alterados. Revisar antes do merge."
    echo
    echo "- UFs adicionadas: ${added_ufs:-nenhuma}"
    echo "- UFs removidas: ${removed:-nenhuma}"
    if [ -n "$removed" ]; then echo "  - ⚠️ Confira se a UF saiu mesmo do catálogo antes de tirar do draft."; fi
    if [ -n "$added_unscoped" ]; then echo "- UFs adicionadas sem escopo na core-api: $added_unscoped. A API devolve 500 nelas até a core-api ter o escopo."; fi
    if [ "$pending" = true ]; then echo "- $pending_line"; fi
    if [ -s "$rows_file" ]; then
      echo
      echo "<details><summary>Linhas de tabela em <code>reference/todas-certidoes.mdx</code> (+$(grep -c '^+' "$rows_file" || true) / -$(grep -c '^-' "$rows_file" || true))</summary>"
      echo
      echo '```diff'
      head -n 80 "$rows_file"
      if [ "$(wc -l < "$rows_file")" -gt 80 ]; then echo "… (veja o diff do PR)"; fi
      echo '```'
      echo
      echo "</details>"
    fi
  } > "$state/api-docs-body.md"
  title="docs(catálogo): sincroniza com o catálogo de prod"
  if [ "$doc_changed" != true ]; then title="docs(catálogo): lembrete de mudança no hydrogen"; fi
  publish api-docs DiligenceHub/DiHub-Api-Docs main automation/catalog-sync \
    "$draft" true "$title" "$state/api-docs-body.md"
fi

# core-api (private): always draft (generated code).
if [ "$core_changed" = true ]; then
  title="feat(catálogo): porta as entradas novas do hydrogen"
  if [ -n "$unscoped" ]; then title="[URGENTE] $title"; fi
  {
    echo "## core-api × hydrogen"
    echo
    echo "Draft do workflow \`catalog-sync\` ([run]($RUN_URL)). Disparo: $trigger. Código gerado por agente: revise a posição das entradas e rode os testes antes do merge."
    echo
    if [ -n "$unscoped" ]; then echo "- **URGENTE:** UFs vendidas em prod sem escopo na core-api (a API devolve 500): $unscoped."; fi
    if [ "$pending" = true ]; then echo "- $pending_line"; fi
    echo
    echo '```text'
    g -C core-api diff --stat
    echo '```'
  } > "$state/core-api-body.md"
  publish core-api DiligenceHub/core-api develop automation/core-api-catalog-sync \
    true false "$title" "$state/core-api-body.md"
fi

# One PR links the other.
docs_url=$(cat "$state/catalog-sync.url" 2>/dev/null || true)
core_url=$(cat "$state/core-api-catalog-sync.url" 2>/dev/null || true)
if [ -n "$docs_url" ] && [ -n "$core_url" ]; then
  printf '\n\nPR relacionado: %s\n' "$core_url" >> "$state/api-docs-body.md"
  printf '\n\nPR relacionado: %s\n' "$docs_url" >> "$state/core-api-body.md"
  gh pr edit "$docs_url" --body-file "$state/api-docs-body.md" >/dev/null
  gh pr edit "$core_url" --body-file "$state/core-api-body.md" >/dev/null
fi

{
  echo "### catalog-sync"
  echo "- doc: ${docs_url:-sem PR}"
  echo "- core-api: ${core_url:-sem PR}"
  if [ "$DRY_RUN" = true ]; then echo "- dry-run: nada foi publicado"; fi
} >> "$GITHUB_STEP_SUMMARY"
