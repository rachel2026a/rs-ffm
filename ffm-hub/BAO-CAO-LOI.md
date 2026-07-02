# Báo cáo rà soát FFM Hub — 02/07/2026

> ✅ **CẬP NHẬT (v1.1):** Đã sửa xong **Lỗi 1 (parse ngày)** và **Lỗi 2 (XSS)**. Đã test lại
> trên file thật: 0 ngày lỗi (trước 31), 0 SLA "NaN" (trước 7), XSS không còn nhúng vào onclick.
> Các điểm phụ (seed trùng xưởng, xưởng rác khi import, `o_ins`) là lựa chọn chuẩn hoá dữ liệu,
> để lại cho bạn quyết. Chi tiết bên dưới giữ nguyên để tham chiếu.


Đã kiểm tra: cú pháp JS (`node --check` 4 script → OK), đối chiếu ID/hàm HTML↔JS (không thiếu),
đối chiếu schema SQL↔code (không lệch bảng/cột), và **chạy parser thật trên file `RSA - FFM.xlsx`**
(10 sheet seller + Tổng hợp, ~3.400 dòng) bằng harness DOM/Supabase giả.

Kết quả: app chạy được, parser đọc đúng ~1.514 đơn / 1.696 SP từ sheet Tổng hợp, không văng.
Nhưng còn **2 lỗi cần xử lý trước khi dùng thật**, cộng vài điểm nhỏ.

---

## 🔴 Lỗi 1 — Parse ngày SAI (nghiêm trọng, làm VỠ import)

**Ở đâu:** hàm `_pDate()` (dòng ~948) và `pDate()` trong `parseCotikJS` (dòng ~1145).

**Vấn đề:** với ô ngày là **text** (không phải Date của Excel), code luôn hiểu theo
**D/M/Y**, trong khi dữ liệu TikTok/US là **M/D/Y**. Test trên file thật:

| Ô gốc (text) | Code đọc ra | Đúng phải là |
|---|---|---|
| `5/31/2026 4:46 PM` | `2026-31-05` ❌ (tháng 31!) | 2026-05-31 |
| `03/07/2026` | `2026-07-03` (7/3) | 2026-03-07 (nếu US) |
| ` 06/17/2026 11:59 PM` (deadline) | `2026-17-06` ❌ | 2026-06-17 |

Trong file thật có **31 giá trị** kiểu này (2 ô Ngày Order + 29 ô Deadline).

**Hậu quả:**
1. Ngày ra `2026-31-05` (tháng 31) → Postgres kiểu `date` **từ chối** → `insert` ném lỗi →
   `runImport` dừng, **cả lô 200 đơn / 500 SP đó không lưu được**. Import file Tổng hợp
   hiện tại sẽ fail giữa chừng.
2. Ngày kiểu `03/07/2026` không sai định dạng nên **lọt qua âm thầm** → lệch tháng/ngày,
   sai SLA, sai thống kê tháng.

**Gợi ý hướng xử lý (bạn quyết):** thống nhất coi text ngày là **M/D/Y** (vì nguồn là
TikTok US); nếu vế đầu >12 thì mới hoán sang D/M. Và với chuỗi có giờ (`... 4:46 PM`)
cần cắt phần giờ trước khi match. Hiện `00:00:00` (chỉ có giờ) đang trả null — chấp nhận được.

---

## 🟠 Lỗi 2 — XSS lưu trữ qua tên khách / Order ID (bảo mật)

**Ở đâu:** `renderAlerts()` dòng 538 (và tương tự chỗ nhúng `a.q` vào `onclick`).

**Vấn đề:** đoạn tạo link:
```js
onclick="S.filters.q='${esc(a.q)}';go('orders');return false"
```
`a.q` là **tên khách** hoặc **Order ID** (khách tự nhập trên sàn). `esc()` đổi `'` thành
`&#39;`, nhưng trong ngữ cảnh **thuộc tính HTML**, trình duyệt **giải mã `&#39;` lại thành `'`
trước khi chạy JS** → chuỗi độc thoát ra được. Đã dựng lại và xác nhận: tên khách kiểu
`x';alert(1);'` sẽ chạy JS tùy ý khi bấm link cảnh báo.

**Hậu quả:** người tạo đơn (khách trên TikTok) có thể chèn mã chạy trên máy nhân viên khi
nhân viên bấm cảnh báo trùng khách. App nội bộ nên rủi ro vừa, nhưng dữ liệu đến từ bên ngoài.

**Gợi ý:** không nhúng dữ liệu vào chuỗi `onclick`. Dùng `data-q="..."` + gắn listener,
hoặc mã hoá cho ngữ cảnh JS (không chỉ HTML). Các chỗ khác dùng `esc()` trong **nội dung**
thẻ thì an toàn — chỉ chuỗi nằm trong `onclick`/attribute là dính.

---

## 🟡 Điểm phụ (nên xử, không gấp)

- **SLA hiện "NaN"** với 7 SP: hệ quả trực tiếp của Lỗi 1 (deadline `2026-17-06` không parse
  được → `new Date(...)` = Invalid). Sửa xong Lỗi 1 là hết.
- **Seed trùng xưởng:** `seed_templates.sql` tạo cả `Zootobear` và `Zootop Bear` (cùng 1 xưởng,
  2 cách viết). File thật dùng cả hai → sẽ thành 2 dòng xưởng riêng, số dư/đối soát bị tách.
  Nên gộp về 1 tên chuẩn.
- **Xưởng lạ khi import:** tên `Done`, `An Book`, `Compassup`, `Cancel`, `?` xuất hiện ở cột
  xưởng (nhân viên gõ tay) → app sẽ tạo xưởng mới theo đúng các tên rác này. Cân nhắc chuẩn hoá
  danh sách hoặc cảnh báo khi tên xưởng không khớp danh mục.
- **`o_ins` (RLS orders)** không ràng buộc `seller_id = auth.uid()` — về lý thuyết seller có thể
  tạo đơn gán cho người khác qua API (UI không cho). Nếu muốn chặt, thêm điều kiện vào `with check`.
- **View `v_order_status`** khai báo trong SQL nhưng code không dùng — vô hại, có thể bỏ.
- **Template 083–085** là placeholder rỗng (`083___`) — vô hại.

---

## Tự chấm điểm: 7.5 / 10

Kiến trúc tốt, bảo mật đặt đúng chỗ (RLS + trigger chặn cột + activity_log), parser chịu được
sheet lệch cột và đọc đúng phần lớn dữ liệu thật. Trừ điểm vì **Lỗi 1 chặn đúng luồng chính
(import file Tổng hợp hiện tại sẽ fail)** và **Lỗi 2 là XSS thật từ dữ liệu ngoài**. Xử xong 2 lỗi
này thì sẵn sàng chạy thật.

**Chưa kiểm được (ngoài tầm ở đây):** hành vi RLS thực tế trên Supabase (đăng nhập/duyệt/care hộ)
và luồng đăng nhập UI — cần test trực tiếp trên project sau khi chạy đủ 5 phần setup.
