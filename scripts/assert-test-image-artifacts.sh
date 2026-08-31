#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 IMAGE MAP SYMBOL_TABLE" >&2
    exit 2
fi

for artifact in "$@"; do
    if [[ ! -f $artifact ]]; then
        echo "Required test-image artifact not found: $artifact" >&2
        exit 2
    fi
    if [[ ! -s $artifact ]]; then
        echo "Required test-image artifact is empty: $artifact" >&2
        exit 2
    fi
done
