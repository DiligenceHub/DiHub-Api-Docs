# shellcheck shell=bash
# Shared by stage.sh (job sync) and publish.sh (job publish).

# The only files that leave the agent job. Same list as the Edit(...) rules
# in catalog-sync.yml and the "Só estes arquivos" list in prompt.md.
# shellcheck disable=SC2034 # used by the scripts that source this file
CS_FILES=(
  api-docs/reference/todas-certidoes.mdx
  api-docs/api-reference/diligences/districts.mdx
  api-docs/openapi.json
  core-api/src/enums/emission.enum.ts
  core-api/src/consts/certificateOrder.consts.ts
  core-api/src/routes/diligences/helpers/__tests__/emission.helper.spec.ts
  out/result.json
)
# shellcheck disable=SC2034
CS_MAX_BYTES=1048576

# Artifact entry name for a file: no directories, fixed per file.
cs_flat() { printf '%s.enc' "${1//\//__}"; }

# Artifact key = HMAC-SHA256(key=$CS_PAT, msg="$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT"), hex.
# python3 reads the PAT from the environment: `openssl dgst -hmac "$PAT"` would put it in argv (ps).
cs_derive_key() {
  python3 -c 'import hashlib, hmac, os
msg = (os.environ["GITHUB_RUN_ID"] + ":" + os.environ["GITHUB_RUN_ATTEMPT"]).encode()
print(hmac.new(os.environ["CS_PAT"].encode(), msg, hashlib.sha256).hexdigest())'
}

# cs_crypt enc|dec <key file> <in> <out>
cs_crypt() {
  local flag=-e
  if [ "$1" = dec ]; then flag=-d; fi
  openssl enc "$flag" -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$2" -in "$3" -out "$4"
}

# True when $1 (relative to the current dir) is a regular file with no symlink
# anywhere on its path.
cs_regular() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(realpath -- "$1")" = "$(pwd -P)/$1" ]
}
