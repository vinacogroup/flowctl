# workflow-conduct

## Mục tiêu
Khi user gọi `/workflow-conduct <topic>`, tự động orchestration theo step hiện tại bằng workflow engine, không yêu cầu user chạy lệnh thủ công.

## Trigger
- User gọi: `/workflow-conduct ...`
- Hoặc yêu cầu tương đương: "chạy tự động theo step hiện tại"

## Hành vi bắt buộc
1. Parse topic từ input user.
2. Gọi trực tiếp workflow engine:
   - `bash scripts/workflow.sh brainstorm "<topic>"`
3. Tôn trọng trạng thái `workflow-state.json`:
   - Nếu chưa init (`current_step = 0`) thì auto init bằng project mặc định hoặc tên user truyền vào.
   - Chỉ delegate đúng agent của step hiện tại.
4. Sau khi dispatch, báo cáo lại:
   - Step hiện tại
   - Roles đã spawn
   - Đường dẫn reports/logs
   - Gợi ý bước kế tiếp (`team sync`, `release-dashboard`, `gate-check`, `approve`)
5. Trước khi đề xuất approve, ưu tiên nhắc user chạy:
   - `bash scripts/workflow.sh release-dashboard`
   - `bash scripts/workflow.sh gate-check`
6. Nếu phát hiện budget breaker đang `open` hoặc `half-open`, nhắc đường recovery:
   - `bash scripts/workflow.sh team budget-reset --reason "manual recovery"`

## Tuỳ chọn mở rộng
- Chạy kèm sync tự động:
  - `bash scripts/workflow.sh brainstorm --sync --wait 30 "<topic>"`
- Kiểm tra trước bằng dry-run:
  - `bash scripts/workflow.sh brainstorm --dry-run "<topic>"`

## Guardrails
- Không tự động approve step.
- Không bỏ qua approval gate.
- Không spawn agent ngoài scope step hiện tại.
- Không gợi ý approve khi `release-dashboard` báo `approval_ready: no`.
