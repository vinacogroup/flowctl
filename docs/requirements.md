# Requirements — Global Workflow CLI

## Product Goal
Biến project hiện tại thành một CLI có thể cài đặt global để khởi tạo và vận hành flowctl nhất quán giữa nhiều project.

## Primary User Stories
- Là developer, tôi muốn cài CLI global một lần và dùng ở mọi repo.
- Là PM/lead, tôi muốn chạy lệnh `init` để tạo scaffold chuẩn gồm `.cursor`, `.claude`, và `flowctl-state.json`.
- Là team member, tôi muốn tất cả hướng dẫn dùng command global thay vì script relative để giảm sai lệch môi trường.

## Functional Requirements
1. CLI hỗ trợ cài đặt global qua package manager chuẩn.
2. Lệnh `init` tạo đầy đủ:
   - `.cursor/`
   - `.claude/`
   - `flowctl-state.json`
   - (mặc định) chạy `scripts/setup.sh` trên `PROJECT_ROOT` (Graphify/MCP/.gitignore); có `--no-setup` / `FLOWCTL_SKIP_SETUP=1` để tắt.
3. `init` có tính idempotent:
   - Không ghi đè file người dùng đã chỉnh nếu không có cờ explicit.
   - Có thông báo rõ file nào được tạo/bỏ qua.
4. Các command flowctl chính chạy qua entrypoint global thay vì `bash scripts/flowctl.sh ...`.
5. Giữ tương thích ngược tối thiểu trong giai đoạn chuyển đổi (alias hoặc fallback command).

## Non-Functional Requirements
- Tính ổn định: command thất bại phải có exit code và thông báo rõ.
- Auditability: hành động quan trọng vẫn ghi logs/reports như hiện tại.
- Portability: chạy được trên môi trường shell tiêu chuẩn macOS/Linux.

## Acceptance Criteria
- Từ một repo trống, chạy global `init` tạo đúng scaffold cần thiết.
- Các tài liệu chính không còn hướng dẫn dùng script relative làm mặc định.
- Gate/check flowctl hoạt động bình thường sau khi chuyển sang command global.
