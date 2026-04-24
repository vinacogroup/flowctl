#!/usr/bin/env bash
set -euo pipefail

current_branch="$(git rev-parse --abbrev-ref HEAD)"

if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  echo "Commit blocked: direct commits on '$current_branch' are not allowed."
  echo "Create a feature branch and open a PR instead."
  exit 1
fi
