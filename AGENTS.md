# Workspace Rules & Natural Intent Classifier (Pmodule)

> Bộ quy tắc cục bộ của dự án `Pmodule` — tối ưu cho phát triển hệ thống Linux / Shell Script / KernelSU Module & KSU WebUI gọn nhẹ. Hỗ trợ nhận diện ý định tự nhiên bằng tiếng Việt và tiếng Anh.

## 1. Nguyên tắc nhận diện ngôn ngữ tiếng Việt tự nhiên
- Thấu hiểu mọi yêu cầu bằng tiếng Việt (bao gồm khẩu ngữ, thuật ngữ hệ thống Android/Linux/KernelSU, cách diễn đạt đời thường).
- Không yêu cầu người dùng phải nhớ hay gõ đúng tên skill tiếng Anh; tự động kích hoạt đúng skill trong `.agents/skills/` dựa theo ngữ cảnh công việc:

### Kiến trúc & Lập kế hoạch (Planning & Architecture)
- *"phân tích kiến trúc / đánh giá trade-off / viết ADR / thiết kế hệ thống"* -> `architecture`
- *"brainstorm tính năng / thảo luận ý tưởng / chốt hướng thiết kế"* -> `brainstorming`
- *"chia nhỏ task / lên checklist công việc ngắn gọn"* -> `plan-writing`
- *"lập kế hoạch triển khai chi tiết / viết plan từng bước"* -> `writing-plans`
- *"thực thi plan / triển khai theo kế hoạch từng checkpoint"* -> `executing-plans`

### Gỡ lỗi & Kiểm thử (Debugging & Testing)
- *"debug lỗi / tìm nguyên nhân gốc rễ / tại sao bị lỗi / điều tra bug"* -> `systematic-debugging`
- *"viết test / kiểm thử hành vi / audit test rác / tối ưu tốc độ test"* -> `smart-test`
- *"chiến lược unit test / integration test / cách mock dữ liệu"* -> `testing-patterns`
- *"kiểm tra cú pháp / chạy lint / static analysis"* -> `lint-and-validate`
- *"kiểm tra trước khi hoàn tất / nghiệm thu bằng chứng thực tế"* -> `verification-before-completion`

### Shell Script, Linux & Hệ thống (Shell / Linux / Systems)
- *"viết shell script / bash / lệnh linux / xử lý chuỗi sed awk grep / quản lý process"* -> `bash-linux`
- *"quản trị tiến trình / daemon / log rotation / giám sát tài nguyên linux"* -> `server-management`
- *"viết script powershell / tự động hóa đóng gói trên windows"* -> `powershell-windows`
- *"đo hiệu năng / tìm điểm nghẽn / tối ưu bộ nhớ & tốc độ tải"* -> `performance-profiling`

### Review Code & Bảo mật (Code Review & Security)
- *"review code chi tiết / đánh giá PR / soi race condition & anti-pattern"* -> `code-review-skill`
- *"checklist rà soát nhanh code / kiểm tra edge case"* -> `code-review-checklist`
- *"rà soát bảo mật / kiểm tra phân quyền, input validation, XSS, injection"* -> `security-review`
- *"quét lỗ hổng / phân tích bề mặt tấn công / OWASP / fail-closed"* -> `vulnerability-scanner`
- *"viết code sạch / refactor gọn lại / chuẩn SOLID, KISS, YAGNI"* -> `clean-code`
- *"viết code đầy đủ / cấm viết tắt / không để placeholder TODO"* -> `full-output-enforcement`

### Giao diện Web gọn nhẹ & KSU WebUI (Lightweight Frontend / WebUI)
- *"thiết kế giao diện web / tạo trang điều khiển / chống AI slop"* -> `frontend-design`
- *"chọn bảng màu, typography, vùng chạm cảm ứng mobile, dark mode"* -> `ui-ux-pro-max`
- *"giao diện tối giản / phẳng, sạch, siêu nhẹ không hiệu ứng rườm rà"* -> `minimalist-ui`
- *"giao diện kỹ thuật / bảng điều khiển hệ thống / telemetry / terminal UI"* -> `industrial-brutalist-ui`
- *"tra cứu chuẩn HTML/CSS/JS hiện đại / Baseline Web APIs không dùng thư viện thừa"* -> `modern-web-guidance`

## 2. Tiêu chuẩn phản hồi & Quy tắc cứng (BLOCKING RULES)
- Ngắn gọn, súc tích, đi thẳng vào giải pháp và mã nguồn thực thi được ngay.
- **[BLOCKING] Tương thích Shell nghiêm ngặt (POSIX `sh` / BusyBox `ash` / Android `mksh`)**:
  - Mọi shell script của module (`customize.sh`, `post-fs-data.sh`, `service.sh`, `boot-completed.sh`, `action.sh`, `uninstall.sh` và các script phụ trợ) **PHẢI** tuân thủ chuẩn POSIX `sh` / BusyBox `ash` / Android `mksh`.
  - **TUYỆT ĐỐI CẤM** dùng cú pháp riêng của GNU Bash: `set -o pipefail`, `[[ ... ]]`, mảng `array=()`, toán tử `+=` nối mảng, biến `BASH_SOURCE`, chuyển hướng `&>` hoặc lệnh `source` (dùng dấu chấm `. "/path/to/file.sh"` để nạp file).
  - Quote đầy đủ mọi biến (`"$VAR"`) và kiểm tra lỗi tường minh.
- **[BLOCKING] Chuẩn xuống dòng & Ghi log vận hành**:
  - Toàn bộ file `.sh` và `.prop` bắt buộc dùng chuẩn xuống dòng UNIX **`LF`** (`\n`), tuyệt đối không chứa `CRLF` (`\r\n`) gây lỗi `/system/bin/sh^M: bad interpreter` hoặc hỏng `system.prop`.
  - Mọi log vận hành của module thống nhất ghi ra `/data/local/tmp/x14_perf_battery.log`.
- **KSU WebUI**: Ưu tiên kiến trúc gọn nhẹ (Vanilla HTML/CSS/JS hoặc bundle tối giản), tải tức thì trong Android System WebView, hỗ trợ tốt thao tác chạm (touch targets >= 44px) và giao diện sáng/tối.
