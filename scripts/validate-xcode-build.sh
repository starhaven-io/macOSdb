#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]] || [[ ! "$1" =~ ^[0-9]+[A-Z][0-9]+[a-z]?$ ]]; then
  exit 1
fi
