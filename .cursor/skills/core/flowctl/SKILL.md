---
name: flowctl
description: "Operational guide for step-based flowctl orchestration commands"
triggers: ["flowctl", "workflow", "approve", "dispatch"]
when-to-use: "Use when operating the flowctl workflow lifecycle and command orchestration."
when-not-to-use: "Do not use for deep code debugging unrelated to workflow orchestration."
prerequisites: []
estimated-tokens: 571
roles-suggested: ["pm", "tech-lead", "devops"]
version: "1.0.0"
tags: ["orchestration", "workflow"]
---
# flowctl-conduct

## Mục tiêu
Khi user gọi `/flowctl-conduct <topic>`, tự động orchestration theo step hiện tại bằng flowctl engine, không yêu cầu user chạy lệnh thủ công.

## Trigger
- User gọi: `/flowctl-conduct ...`
- Hoặc yêu cầu tương đương: "chạy tự động theo step hiện tại"

## Hành vi bắt buộc
1. Parse topic từ input user.
2. Nếu không phải dry-run, chạy flow tự động:
   - `flowctl brainstorm --headless "<topic>"`
   - Poll `flowctl team monitor --stale-seconds 300` mỗi 20-30 giây (tối đa 10 phút)
   - Khi workers kết thúc ổn định: `flowctl team sync`
   - Sau sync, luôn chạy:
     - `flowctl release-dashboard --no-write`
     - `flowctl gate-check`
3. Tôn trọng trạng thái `flowctl-state.json`:
   - Nếu chưa init (`current_step = 0`) thì auto init bằng project mặc định hoặc tên user truyền vào.
   - Chỉ delegate đúng agent của step hiện tại.
4. Logic tự hồi phục khi chạy tự động:
   - Nếu breaker `open`/`half-open` → `flowctl team budget-reset --reason "manual recovery from flowctl-conduct"`
   - Nếu role `blocked` và còn retry budget → `flowctl team recover --role <role> --mode retry`
   - Nếu role `stale` → `flowctl team recover --role <role> --mode resume`
5. Sau khi dispatch/sync, báo cáo lại:
   - Step hiện tại
   - Roles đã spawn
   - Đường dẫn reports/logs
   - Gợi ý bước kế tiếp (`team sync`, `release-dashboard`, `gate-check`, `approve`)
6. Trước khi đề xuất approve, ưu tiên nhắc user chạy:
   - `flowctl release-dashboard`
   - `flowctl gate-check`
7. Nếu phát hiện budget breaker đang `open` hoặc `half-open`, nhắc đường recovery:
   - `flowctl team budget-reset --reason "manual recovery"`

## Tuỳ chọn mở rộng
- Chạy kèm sync tự động:
  - `flowctl brainstorm --sync --wait 30 "<topic>"`
- Kiểm tra trước bằng dry-run:
  - `flowctl brainstorm --dry-run "<topic>"`

## Guardrails
- Không tự động approve step (trừ khi user yêu cầu rõ ràng).
- Không bỏ qua approval gate.
- Không spawn agent ngoài scope step hiện tại.
- Không gợi ý approve khi `release-dashboard` báo `approval_ready: no`.
