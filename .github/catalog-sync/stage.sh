#!/usr/bin/env bash
# Job sync, after the agent: encrypts the allowed files, by fixed name, for the
# publish job. No PAT here; the key was derived before the agent ran.
# usage: stage.sh <output dir>
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

key="$RUNNER_TEMP/catalog-sync.key"
dest=$1
mkdir -p "$dest"

if ! cs_regular out/result.json; then
  echo "::error::Claude não gravou out/result.json (rodada incompleta)"
  exit 1
fi
for f in "${CS_FILES[@]}"; do
  if ! cs_regular "$f"; then
    echo "::error::$f ausente ou não é arquivo regular"
    exit 1
  fi
  if [ "$(wc -c < "$f")" -gt "$CS_MAX_BYTES" ]; then
    echo "::error::$f passa de $CS_MAX_BYTES bytes"
    exit 1
  fi
  cs_crypt enc "$key" "$f" "$dest/$(cs_flat "$f")"
done
rm -f "$key"
