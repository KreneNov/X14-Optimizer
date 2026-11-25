---
trigger: model_decision
description: "Áp dụng khi viết hoặc tối ưu Shell Script cho Linux / Android / KernelSU module (customize.sh, post-fs-data.sh, service.sh, action.sh, webroot) hoặc thiết kế giao diện KSU WebUI."
---

# Quy Tắc Chuyên Biệt: KernelSU Module Shell Scripts & KSU WebUI

## 1. Shell Script Hệ Thống & KernelSU (`*.sh`, `*.prop`) — [BLOCKING RULES]
- **[BLOCKING] Cấm tuyệt đối Bashisms (Strict POSIX `sh` / BusyBox `ash` / Android `mksh`)**:
  - Toàn bộ script của module (`customize.sh`, `post-fs-data.sh`, `service.sh`, `boot-completed.sh`, `action.sh`, `uninstall.sh`) chạy trên BusyBox `ash` hoặc Android `mksh` (`/system/bin/sh`).
  - **TUYỆT ĐỐI CẤM** sử dụng các cú pháp đặc thù của Bash:
    - Cấm `set -o pipefail`
    - Cấm `[[ ... ]]` (bắt buộc dùng `[ ... ]` hoặc `case ... in`)
    - Cấm mảng `array=()` và truy xuất `${array[@]}`
    - Cấm `source` (bắt buộc dùng `. "/duong/dan/script.sh"`)
    - Cấm `BASH_SOURCE`, `function foo()`, chuyển hướng `&>` (dùng `>/dev/null 2>&1`)
  - Luôn lấy thư mục module chuẩn bằng `MODDIR=${0%/*}`.
- **[BLOCKING] Định dạng xuống dòng UNIX `LF` & Đường dẫn Log chuẩn**:
  - Mọi file `.sh` và `.prop` phải lưu với chuẩn kết thúc dòng UNIX **`LF`** (`\n`), cấm để lọt ký tự `\r` (`CRLF`) từ Windows. Luôn kiểm tra không còn `\r` trước khi đóng gói.
  - Đường dẫn ghi log vận hành tiêu chuẩn của module: `/data/local/tmp/x14_perf_battery.log` (kèm kiểm soát kích thước/xoay vòng log để tránh phình file tạm).
- **An toàn với quyền Root**:
  - Bọc ngoặc kép mọi biến đường dẫn (`"$MODDIR"`, `"$TMPDIR"`, `"$MODPATH"`). Tuyệt đối tránh `rm -rf "$VAR/*"` khi chưa kiểm tra `[ -n "$VAR" ]` và đường dẫn hợp lệ.
  - Với `post-fs-data.sh`: giữ thời gian chạy cực ngắn (tránh block quá trình boot); đẩy các tác vụ chờ boot hoặc chạy nền sang `service.sh` hoặc `boot-completed.sh`.
  - Ghi file cấu hình theo kiểu nguyên tử (ghi ra file `.tmp` cùng thư mục rồi `mv -f`) và kiểm tra quyền (`chmod`, `chown`, SELinux context `chcon` nếu cần).

## 2. Thiết Kế KSU WebUI (`webroot/`)
- **Kiến trúc siêu nhẹ**:
  - Ưu tiên HTML5 + CSS Variables + Vanilla ES Modules (hoặc Vite bundle siêu nhỏ không runtime thừa) để mở tức thì trong Android WebView của KernelSU Manager.
  - Không tải font/CDN ngoài nếu module cần hoạt động offline hoặc trên thiết bị chặn mạng cho root manager; ưu tiên system font stack hoặc font nội bộ tối ưu dung lượng.
- **Tương tác Cầu nối KernelSU (`kernelsu` API)**:
  - Đóng gói lệnh gọi `exec` / `spawn` / `toast` qua một lớp adapter mỏng có cơ chế mock fallback khi chạy thử trên trình duyệt desktop (`localhost`) để dễ phát triển và kiểm thử UI.
  - Sanitize / escape mọi tham số người dùng nhập trên WebUI trước khi truyền xuống chuỗi lệnh shell của `exec()` để chống **Command Injection** dưới quyền root.
- **UX trên màn hình cảm ứng (Mobile WebView)**:
  - Vùng chạm tối thiểu `44x44px`, tránh phụ thuộc vào `:hover`, xử lý `env(safe-area-inset-*)` (status bar / navigation bar insets của KernelSU WebView) và hỗ trợ mượt Dark/Light mode.
