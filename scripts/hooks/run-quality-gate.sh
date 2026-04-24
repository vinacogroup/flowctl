#!/usr/bin/env bash
set -euo pipefail

mode="ci"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      mode="${2:-ci}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: run-quality-gate.sh [--mode ci|local]" >&2
      exit 1
      ;;
  esac
done

if [[ "$mode" == "local" ]]; then
  echo "[gate] Running local quality gate: npm run test:tdd"
  npm run test:tdd
  exit 0
fi

if [[ "$mode" == "ci" ]]; then
  echo "[gate] Running CI quality gate: npm run test:ci:core"
  npm run test:ci:core
  exit 0
fi

echo "Invalid mode: $mode (expected ci|local)" >&2
exit 1
