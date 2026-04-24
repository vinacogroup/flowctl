# flowctl

CLI điều phối quy trình làm việc theo step cho team sản phẩm/kỹ thuật, kèm MCP servers để giảm token và chuẩn hóa context loading.

## Tính năng chính

- Quản lý state theo step với `flowctl-state.json`.
- Điều phối quy trình PM: Complexity -> War Room -> Dispatch -> Collect -> Phase B -> Gate/Approve.
- Hỗ trợ blockers, decisions, approvals, dashboard release.
- Tích hợp MCP servers thông qua `flowctl mcp --shell-proxy|--workflow-state`.
- Dùng thống nhất global command: `flowctl ...`.

## Cấu trúc chính

- `flowctl`: CLI chính (entrypoint global qua `bin/flowctl`).
- `bin/flowctl`: entrypoint để cài global.
- `scripts/workflow/mcp/shell-proxy.js`: Shell Proxy MCP server.
- `scripts/workflow/mcp/workflow-state.js`: Workflow State MCP server.
- `flowctl-state.json`: state runtime của project.
- `.cursor/mcp.json`: cấu hình MCP cho Cursor.

## Yêu cầu

- `bash` (macOS/Linux).
- `python3` + `pip` (cho setup/index Graphify).
- `node` + `npm` (cho MCP JS server, GitNexus).

## Cài đặt local

```bash
# trong repo (cùng thư mục project cần setup)
bash scripts/setup.sh

# khởi tạo flow mới (mặc định chạy setup luôn; CI: FLOWCTL_SKIP_SETUP=1 hoặc --no-setup)
flowctl init --project "Tên dự án"
```

## Cài global (khuyến nghị cho người dùng)

### Từ GitHub

```bash
npm i -g git+https://github.com/<org-or-user>/<repo>.git
flowctl --help
```

### Từ npm registry (nếu publish npm)

```bash
npm i -g flowctl
flowctl --help
```

> Lưu ý: nếu muốn publish npm, cần bỏ `"private": true` trong `package.json`.

## Cấu hình MCP (chuẩn mới)

`flowctl` cung cấp wrapper command để Cursor start MCP từ thư mục `scripts/workflow/mcp/`:

- `flowctl mcp --shell-proxy`
- `flowctl mcp --workflow-state`

Ví dụ `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "shell-proxy": {
      "command": "flowctl",
      "args": ["mcp", "--shell-proxy"]
    },
    "flowctl-state": {
      "command": "flowctl",
      "args": ["mcp", "--workflow-state"]
    }
  }
}
```

## Command nhanh

### Lifecycle cơ bản

- `flowctl init --project "Name"`: khởi tạo state/scaffold và chạy `scripts/setup.sh` (Graphify/MCP). Thêm `--no-setup` hoặc `FLOWCTL_SKIP_SETUP=1` để bỏ qua. `.cursor/mcp.json` được **merge** (chỉ thêm server flowctl còn thiếu) trừ khi `--overwrite`; JSON lỗi sẽ được cảnh báo và gợi ý `--overwrite`.
- `flowctl status`: xem trạng thái hiện tại.
- `flowctl start`: bắt đầu step hiện tại.
- `flowctl summary`: tóm tắt step.
- `flowctl history`: lịch sử approvals.
- `flowctl reset <step>`: reset về step.

### Gate & Approval

- `flowctl gate-check`: kiểm tra QA gate.
- `flowctl approve --by "PM"`: approve step và advance.
- `flowctl approve --skip-gate --by "PM"`: bypass gate (không khuyến nghị).
- `flowctl reject "reason"`: reject step.
- `flowctl conditional "items"`: approve có điều kiện.

### Blocker & Decision

- `flowctl blocker add "desc"`
- `flowctl blocker resolve <id>`
- `flowctl blocker reconcile`
- `flowctl decision "desc"`

### Dispatch orchestration

- `flowctl complexity`
- `flowctl war-room`
- `flowctl war-room merge`
- `flowctl cursor-dispatch`
- `flowctl cursor-dispatch --skip-war-room`
- `flowctl cursor-dispatch --merge`
- `flowctl collect`
- `flowctl mercenary scan`
- `flowctl mercenary spawn`
- `flowctl release-dashboard --no-write`
- `flowctl retro`

### Team mode

- `flowctl team start`
- `flowctl team delegate`
- `flowctl team sync`
- `flowctl team status`
- `flowctl team monitor`
- `flowctl team recover`
- `flowctl team budget-reset`
- `flowctl team run`

### Hạ tầng/MCP

- `flowctl monitor [--once] [--port=N] [--interval=N]` (mở web dashboard tại localhost)
- `flowctl mcp --shell-proxy`
- `flowctl mcp --workflow-state`

## Quy trình PM chuẩn (đề xuất)

### Phase 0 - Complexity

```bash
flowctl status
flowctl complexity
```

- Score 1-2: chạy thẳng Dispatch.
- Score 3-5: chạy War Room trước.

### Phase 0b - War Room (khi cần)

```bash
flowctl cursor-dispatch
# hoàn tất phân tích PM + TechLead
flowctl cursor-dispatch --merge
```

### Phase A - Dispatch team

```bash
flowctl cursor-dispatch --skip-war-room
```

### Phase A Collect

```bash
flowctl collect
```

### Phase B - Mercenary (nếu collect báo cần)

```bash
flowctl mercenary spawn
```

### Gate + Approval recommendation

```bash
flowctl gate-check
flowctl release-dashboard --no-write
```

Sau khi user approve:

```bash
flowctl approve --by "PM"
flowctl retro
```

## Troubleshooting

- `flowctl: command not found`:
  - Cài global lại (`npm i -g ...`) hoặc thêm repo vào `PATH` để dùng `bin/flowctl`.
- MCP không start:
  - Kiểm tra `.cursor/mcp.json` dùng `flowctl mcp --...`.
  - Kiểm tra `flowctl --help` có subcommand `mcp`.
- Thiếu quyền thực thi:
  - `chmod +x bin/flowctl scripts/flowctl.sh`.
- Setup lỗi dependencies:
  - kiểm tra `python3`, `pip`, `node`, `npm` trong `PATH`.

## Development notes

- Chuẩn sử dụng:
  - `flowctl ...`
- Khi thêm command mới, cập nhật cả:
  - help text trong `scripts/flowctl.sh`
  - `README.md`
  - (nếu cần) template `.cursor/mcp.json` trong `scripts/setup.sh`

