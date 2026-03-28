#!/bin/bash
# Validate all IPSWs in the macOS archive, one file at a time.
# Each file runs as a separate process so OOM only kills that file.
# Sidecar (.sha256) = done — safe to restart at any time.
set -euo pipefail

DIR="${1:-/Volumes/macOS-Archive/macOS}"
PKG="${MACOSDB_PKG:-$HOME/Developer/macOSdb}"

swift build --package-path "$PKG" --product macosdb 2>&1
MACOSDB="$(swift build --package-path "$PKG" --product macosdb --show-bin-path)/macosdb"

hashed=0
skipped=0
failed=0
total=0

while IFS= read -r -d '' ipsw; do
    total=$((total + 1))
    name=$(basename "$ipsw")
    sidecar="${ipsw}.sha256"

    if [[ -f "$sidecar" ]]; then
        printf '%s  ✓ already verified\n' "$name"
        skipped=$((skipped + 1))
        continue
    fi

    if $MACOSDB validate "$ipsw"; then
        hashed=$((hashed + 1))
    else
        status=$?
        if [[ $status -eq 137 || $status -eq 9 ]]; then
            printf '  ⚠ Process killed (OOM?) — will retry on next run\n'
        fi
        failed=$((failed + 1))
    fi
done < <(find "$DIR" -name '*.ipsw' -print0 | sort -z)

printf '\n'
[[ $hashed  -gt 0 ]] && printf '%d hashed, '  "$hashed"
[[ $skipped -gt 0 ]] && printf '%d already verified, ' "$skipped"
[[ $failed  -gt 0 ]] && printf '%d failed, '  "$failed"
printf '(%d total)\n' "$total"

[[ $failed -eq 0 ]]
