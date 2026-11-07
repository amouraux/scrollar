#!/bin/sh
# ./run.sh <orcid> [--days 30] [--top 15]
set -e
cd "$(dirname "$0")"
mkdir -p .build
swiftc -swift-version 5 -O Core/*.swift CLI/main.swift -o .build/scrollar
exec .build/scrollar "$@"
