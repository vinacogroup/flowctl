#!/usr/bin/env bash
# ============================================================
# IT Product Team Workflow — Auto Setup
# Cài đặt Graphify, GitNexus và cấu hình MCP servers
#
# Chạy:
#   cd /path/to/project && bash /path/to/flowctl/scripts/setup.sh [--mcp-only | --index-only]
# Hoặc đặt FLOWCTL_PROJECT_ROOT=/path/to/project (không cần cd).
#
# flowctl init gọi script này với FLOWCTL_PROJECT_ROOT (merge MCP, không ghi đè servers lạ).
# ============================================================

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${CYAN}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

MODE="${1:-all}"
REPO_ROOT="${FLOWCTL_PROJECT_ROOT:-$PWD}"

echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}   IT Product Team Workflow — Setup Script${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
info "Project root: $REPO_ROOT"

# ── 1. Check prerequisites ───────────────────────────────────
check_prerequisites() {
  info "Kiểm tra prerequisites..."

  command -v python3 &>/dev/null || err "Python 3 chưa được cài. Cài tại: https://python.org"
  command -v pip    &>/dev/null || command -v pip3 &>/dev/null \
    || err "pip chưa được cài. Chạy: python3 -m ensurepip"
  command -v node   &>/dev/null || warn "Node.js chưa được cài — GitNexus MCP sẽ bị skip"
  command -v npm    &>/dev/null || warn "npm chưa được cài — GitNexus MCP sẽ bị skip"

  log "Prerequisites OK"
}

# ── 2. Install Graphify ──────────────────────────────────────
install_graphify() {
  info "Cài đặt Graphify (codebase knowledge graph)..."

  # Thử import trước — nếu đã có thì skip
  if python3 -c "import graphify" &>/dev/null; then
    log "Graphify đã được cài (skip)"
  else
    pip install graphifyy --quiet \
      || pip3 install graphifyy --quiet \
      || err "Không thể cài Graphify. Chạy thủ công: pip install graphifyy"
    log "Graphify đã cài xong"
  fi

}

# ── 3. Install GitNexus ──────────────────────────────────────
install_gitnexus() {
  if ! command -v node &>/dev/null; then
    warn "Bỏ qua GitNexus (Node.js không có sẵn)"
    return 0
  fi

  info "Cài đặt GitNexus (code intelligence engine)..."

  if npx gitnexus --version &>/dev/null 2>&1; then
    log "GitNexus đã được cài (skip)"
    return 0
  fi

  # GitNexus chạy qua npx, không cần global install
  npm install --prefix "$REPO_ROOT/.gitnexus" gitnexus 2>/dev/null \
    || warn "npm install gitnexus thất bại — sẽ dùng npx gitnexus khi cần"

  log "GitNexus sẵn sàng (qua npx)"
}

# ── 4. Install flowctl MCP dependencies ─────────────────────
install_mcp_deps() {
  if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    warn "Bỏ qua MCP deps (Node.js/npm không có sẵn)"
    return 0
  fi

  # Chỉ cần chạy khi dùng từ source repo (không phải global install).
  # Khi install qua `npm install -g @vinacogroup/flowctl`, npm đã cài
  # @modelcontextprotocol/sdk tự động — không cần bước này.
  # Resolve flowctl package dir từ vị trí script này (scripts/setup.sh → parent = package root)
  local flowctl_pkg_dir
  flowctl_pkg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
  local pkg_json="$flowctl_pkg_dir/package.json"
  local node_modules="$flowctl_pkg_dir/node_modules/@modelcontextprotocol"
  if [[ -f "$pkg_json" && ! -d "$node_modules" ]]; then
    info "Cài đặt MCP SDK dependencies (dev/source mode)..."
    npm install --prefix "$flowctl_pkg_dir" --prefer-offline 2>/dev/null \
      && log "MCP dependencies đã cài xong" \
      || warn "npm install thất bại — chạy thủ công: cd $flowctl_pkg_dir && npm install"
  else
    log "MCP dependencies OK (skip)"
  fi
}

# ── 5. Index codebase với Graphify ───────────────────────────
index_codebase() {
  info "Đang index codebase với Graphify..."

  cd "$REPO_ROOT"

  # Tạo .graphifyignore nếu chưa có (exclude non-code files)
  local ignore_file="$REPO_ROOT/.graphifyignore"
  if [[ ! -f "$ignore_file" ]]; then
    cat > "$ignore_file" <<'EOF'
# flowctl: exclude workflow/config files from code graph
CLAUDE.md
AGENTS.md
*.md
.cursor/
workflows/
plans/
graphify-out/
scripts/
*.sh
*.json
*.yaml
*.yml
EOF
    log ".graphifyignore đã tạo"
  fi

  # Install git hooks for auto re-index on commit
  if python3 -c "import graphify" &>/dev/null 2>&1; then
    python3 -m graphify hook install 2>/dev/null \
      && log "Graphify git hooks đã cài" \
      || warn "graphify hook install thất bại — graph sẽ không tự cập nhật khi commit"
  fi

  # Build knowledge graph → graphify-out/graph.json (output path cố định của graphify)
  python3 -m graphify update . \
    2>/dev/null \
    && log "Graphify index hoàn thành → graphify-out/graph.json" \
    || warn "graphify index thất bại — chạy thủ công: python3 -m graphify update ."
}

# ── 5. Tạo .cursor/mcp.json ──────────────────────────────────
configure_cursor_mcp() {
  info "Cấu hình Cursor MCP servers..."

  CURSOR_DIR="$REPO_ROOT/.cursor"
  mkdir -p "$CURSOR_DIR"

  local merge_py merge_rc=0 py_out
  merge_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge_cursor_mcp.py"
  [[ -f "$merge_py" ]] || err "Không tìm thấy $merge_py"

  py_out="$(python3 "$merge_py" --setup "$CURSOR_DIR/mcp.json")" || merge_rc=$?
  if [[ "$merge_rc" -eq 2 ]]; then
    warn ".cursor/mcp.json không đọc được (JSON lỗi) — sửa tay hoặc chạy flowctl init --overwrite rồi chạy lại setup"
    return 0
  fi
  [[ "$merge_rc" -eq 0 ]] || err "merge_cursor_mcp.py thất bại (exit $merge_rc)"

  case "$py_out" in
    MCP_STATUS=created)     log ".cursor/mcp.json đã tạo mới" ;;
    MCP_STATUS=overwritten) log ".cursor/mcp.json đã ghi đè (template setup)" ;;
    MCP_STATUS=merged)      log ".cursor/mcp.json đã merge (thêm server còn thiếu)" ;;
    MCP_STATUS=unchanged)   log ".cursor/mcp.json đã đồng bộ (không thiếu server flowctl)" ;;
    *) log ".cursor/mcp.json đã cập nhật" ;;
  esac

  # Install graphify Cursor integration (adds MCP server entry for Cursor)
  if python3 -c "import graphify" &>/dev/null 2>&1; then
    python3 -m graphify cursor install 2>/dev/null \
      && log "Graphify Cursor MCP đã cài" \
      || warn "graphify cursor install thất bại — thêm thủ công nếu cần"
  fi
}

# ── 6. Tạo .gitignore entries ────────────────────────────────
update_gitignore() {
  GITIGNORE="$REPO_ROOT/.gitignore"

  info "Cập nhật .gitignore..."

  # Tạo nếu chưa có
  [[ -f "$GITIGNORE" ]] || touch "$GITIGNORE"

  # Thêm entries nếu chưa có
  local entries=(
    "graphify-out/cache/"
    "graphify-out/memory/"
    ".gitnexus/"
    "node_modules/"
    "__pycache__/"
    "*.pyc"
    ".env"
    ".env.local"
  )

  for entry in "${entries[@]}"; do
    grep -qxF "$entry" "$GITIGNORE" || echo "$entry" >> "$GITIGNORE"
  done

  # Track graph output nhưng không track cache/memory
  grep -qxF "!graphify-out/graph.json" "$GITIGNORE" \
    || echo "!graphify-out/graph.json" >> "$GITIGNORE"

  log ".gitignore đã cập nhật"
}

# ── 7. Khởi động MCP servers (background) ───────────────────
start_mcp_servers() {
  info "Khởi động MCP servers..."

  # Graphify MCP server — chạy qua stdio (Cursor tự quản lý process)
  # Không cần start thủ công, mcp.json đã cấu hình sẵn
  if python3 -c "import graphify" &>/dev/null; then
    log "Graphify đã cài — Cursor sẽ tự start MCP server từ mcp.json"
  else
    warn "Graphify chưa cài — chạy: pip install graphifyy"
  fi

  log "MCP servers đã được cấu hình. Cursor sẽ tự khởi động khi cần."
}

# ── 8. Summary ───────────────────────────────────────────────
print_summary() {
  echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}   Setup hoàn thành!${NC}"
  echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${CYAN}Bước tiếp theo:${NC}"
  echo -e "  1. Mở Cursor và reload window (Cmd/Ctrl+Shift+P → Reload)"
  echo -e "  2. Kiểm tra MCP servers: Cursor → Settings → MCP"
  echo -e "  3. Bắt đầu flowctl: ${YELLOW}flowctl start${NC}"
  echo -e "  4. Xem trạng thái:   ${YELLOW}flowctl status${NC}"
  echo ""
  echo -e "  ${CYAN}Files quan trọng:${NC}"
  echo -e "  • CLAUDE.md          — Orchestration guide cho agents"
  echo -e "  • flowctl-state.json — Trạng thái flowctl hiện tại"
  echo -e "  • .cursor/mcp.json   — MCP server configuration"
  echo -e "  • graphify-out/graph.json — Codebase knowledge graph"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────
main() {
  case "$MODE" in
    --mcp-only)
      check_prerequisites
      configure_cursor_mcp
      ;;
    --index-only)
      install_graphify
      index_codebase
      ;;
    all|*)
      check_prerequisites
      install_mcp_deps
      install_graphify
      install_gitnexus
      [[ "$MODE" != "--no-index" ]] && index_codebase
      configure_cursor_mcp
      update_gitignore
      start_mcp_servers
      print_summary
      ;;
  esac
}

main "$@"
