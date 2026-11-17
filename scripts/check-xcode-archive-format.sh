#!/bin/bash
set -euo pipefail

# Prints a description of the archive. Exits 0 when it is in the named format,
# 1 when it is confirmed to be something else, 2 on bad usage, and 3 when it
# could not be read. Callers remove a fresh download only on 1, so a failed
# read never costs a usable archive.
#
# The leading bytes are read here instead of asking file(1), which describes a
# file it cannot open or read and still exits 0, and names an .aea only as data.
if [[ $# -ne 2 ]]; then
  exit 2
fi
case "$1" in
  xip)
    expected="78617221"
    name="xar archive"
    article="a"
    ;;
  aea)
    expected="41454131"
    name="Apple Encrypted Archive"
    article="an"
    ;;
  *)
    exit 2
    ;;
esac
if [[ ! -f "$2" ]]; then
  exit 3
fi
magic=$(head -c 4 -- "$2" | od -An -tx1 | tr -d ' \n') || exit 3
if [[ "${magic}" != "${expected}" ]]; then
  printf 'not %s %s (leading bytes %s)\n' "${article}" "${name}" "${magic:-none}"
  exit 1
fi
printf '%s\n' "${name}"
