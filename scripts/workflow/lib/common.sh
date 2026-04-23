#!/usr/bin/env bash

# Shared colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

now() { date '+%Y-%m-%d %H:%M:%S'; }
today() { date '+%Y-%m-%d'; }

ensure_dir() { mkdir -p "$1"; }
