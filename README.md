# A1 Tool cho iPad (TrollStore)

App SwiftUI nhập liệu A1-Stream bằng API, chuyển từ bản Rust/Windows. Đủ 4 chế độ:
**Kiểm tra xe** (chỉ đọc) · **Sửa chữa** · **Nhập liệu BT** · **Kết thúc BT/DV**.

## Khác bản Windows
- Không dùng Chrome cổng debug. Đăng nhập A1-Stream ngay trong app (nút **Đăng nhập** → trình duyệt nhúng). App lấy token + cookie từ đó.
- Không dùng Excel. **Dán** danh sách (copy từ Excel/Sheets/Zalo) hoặc **Nhập file** CSV/TXT. Kết quả xuất **CSV** (nút chia sẻ).
- Chế độ Kết thúc: nút "Lấy số đơn từ lần chạy trước" lấy luôn Số Đơn hàng của lần Sửa chữa / Nhập BT gần nhất.
- Giữ nguyên quy tắc an toàn: lệnh ghi chỉ gửi 1 lần, phân biệt "chưa lưu" / "CÓ THỂ ĐÃ LƯU", có hộp xác nhận trước khi ghi thật, nút Dừng ngay, giãn cách giữa các mục.
- Chưa có: file lịch sử nhập (lich_su), đọc trực tiếp .xlsx.

## Định dạng danh sách (Tab, dấu phẩy, chấm phẩy hoặc | đều được)
- Kiểm tra xe: `Số khung`
- Sửa chữa: `Số khung, KTV, Mã Công Việc, Số Tiền`
- Nhập liệu BT: `Số khung, KTV, Phụ tùng` (phụ tùng có thể bỏ trống). Mục "Số lượng dừng": `Mã phụ tùng, Số lượng dừng`
- Kết thúc: `Số Đơn hàng` mỗi dòng 1 đơn

## Build ra file .ipa (GitHub Actions, không cần Mac)
1. Tạo repo mới trên GitHub, đẩy **toàn bộ nội dung thư mục này** lên nhánh `main` (phải có thư mục `.github/workflows`).
2. Vào tab **Actions** → **Build IPA** → **Run workflow** (hoặc tự chạy khi push).
3. Chạy xong, mở lần chạy đó → mục **Artifacts** → tải **A1Tool-ipa** (zip chứa `A1Tool.ipa`).
4. Giải nén, chuyển `A1Tool.ipa` sang iPad, mở bằng **TrollStore** → Install.

Nếu build lỗi: mở bước bị đỏ trong Actions, chép nội dung lỗi gửi lại để sửa.

## Dùng lần đầu
1. Bấm **Đăng nhập** → đăng nhập A1-Stream trong trình duyệt nhúng (hoặc menu ⋯ → Tài khoản đã lưu → nhập username/mật khẩu/khoá TOTP, rồi **Tự đăng nhập**).
2. Đóng cửa sổ, chọn chế độ, dán danh sách, bấm **Bắt đầu**.
3. Chạy các chế độ ghi: để iPad sáng màn hình và giữ app ở phía trước (iOS tạm dừng app nền).
4. Nên thử **Kiểm tra xe** (chỉ đọc) trước để chắc token/đăng nhập chạy được.
