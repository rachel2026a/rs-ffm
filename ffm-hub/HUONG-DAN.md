# HƯỚNG DẪN ĐƯA APP RSA FFM LÊN WEB (từ đầu, chi tiết)

Dành cho người **không rành kỹ thuật**. Làm lần lượt từ trên xuống, khoảng 30–45 phút.
App gồm 1 thư mục file tĩnh (`ffm-hub`) + 1 database Supabase. Không cần biết lập trình.

Bạn sẽ cần 3 tài khoản (đều miễn phí, đăng nhập bằng Google được):
1. **Supabase** — chứa dữ liệu (đơn hàng, người dùng…). Bạn đã có project `lkdddz…`.
2. **GitHub** — chứa mã nguồn (các file trong `ffm-hub`).
3. **Vercel** — biến mã nguồn thành 1 đường link web chạy được.

---

## PHẦN 0 — Dọn 1 thứ trước khi bắt đầu

Trong thư mục `D:\AI\Tool FFM 2\ffm-hub` có 1 thư mục ẩn tên **`.git`** (do quá trình làm việc tạo ra, bị lỗi dở). **Xoá nó đi** để lát nữa không vướng:

- Mở **Command Prompt** (bấm phím Windows, gõ `cmd`, Enter), dán dòng này rồi Enter:
  ```
  rmdir /s /q "D:\AI\Tool FFM 2\ffm-hub\.git"
  ```
- Nếu báo "not found" thì càng tốt (không có gì để xoá).

---

## PHẦN 1 — Cài database trên Supabase (10 phút)

1. Vào https://supabase.com → **Sign in** → chọn project của bạn (`lkdddz…`).
2. Cột trái, tìm biểu tượng **SQL Editor** (hình `</>`) → bấm vào.
3. Bấm **+ New query** (góc trên).
4. Mở file **`supabase-setup.sql`** trong thư mục `ffm-hub` bằng Notepad → **Ctrl+A** (chọn hết) → **Ctrl+C** (copy).
5. Quay lại ô SQL Editor trống → **Ctrl+V** (dán) → bấm nút **Run** (góc dưới phải, hoặc Ctrl+Enter).
6. Đợi vài giây, thấy dòng **"Success. No rows returned"** màu xanh là xong.
   - File này an toàn chạy lại nhiều lần, không làm mất dữ liệu đang có.
7. Làm lại y hệt bước 3–6 nhưng với file **`seed_templates.sql`** (nạp 85 Template auto-fill).

> Nếu Run ra **chữ đỏ (lỗi)**: copy nguyên dòng lỗi gửi cho tôi. Đừng làm tiếp.

---

## PHẦN 2 — Bật đăng ký + tạo tài khoản Admin của bạn (5 phút)

**2a. Bật đăng ký bằng email:**
- Supabase → cột trái **Authentication** → **Sign In / Providers** → **Email** → bật **Enable Email Sign up**.
- Kéo xuống tắt **Confirm email** (để nhân sự đăng nhập được ngay). Bấm **Save**.
  - An toàn: chưa được bạn duyệt thì họ không thấy dữ liệu gì (database tự chặn).

**2b. Tạo tài khoản Admin (làm SAU khi đã deploy web ở Phần 4, hoặc test local):**
- Bạn cần đăng ký 1 lần trên chính web app (Phần 4 xong mới có link). Tạm ghi nhớ:
  sau khi đăng ký bằng email `lehieu1497@gmail.com`, quay lại Supabase → SQL Editor → New query →
  dán và Run:
  ```sql
  update profiles set role='admin', approved=true,
    view_scope='all', edit_scope='all', delete_scope='all'
  where email = 'lehieu1497@gmail.com';
  ```
- Từ giờ bạn là Admin (SD), có quyền duyệt người khác.

---

## PHẦN 3 — Đưa mã nguồn lên GitHub (10 phút, dùng app cho dễ)

Cách dễ nhất cho người không rành lệnh: dùng **GitHub Desktop**.

1. Tải **GitHub Desktop**: https://desktop.github.com → cài đặt → đăng nhập (tạo tài khoản GitHub nếu chưa có).
2. Trong GitHub Desktop: menu **File → Add local repository** → chọn thư mục `D:\AI\Tool FFM 2\ffm-hub` → **Add repository**.
   - Nếu nó báo "chưa phải repository, tạo mới?" → bấm **create a repository** → **Create**.
3. Nó sẽ liệt kê các file. **Yên tâm**: file nhạy cảm (Excel, seed_data, báo cáo) đã được `.gitignore` tự loại — không lên mạng.
4. Ô dưới trái: gõ tên commit (vd `RSA FFM v1.1`) → bấm **Commit to main**.
5. Bấm **Publish repository** (góc trên phải).
   - **QUAN TRỌNG: TÍCH vào ô "Keep this code private"** (để mã nguồn riêng tư) → **Publish repository**.

Xong — mã nguồn đã lên GitHub (riêng tư).

---

## PHẦN 4 — Deploy lên Vercel để có link web (5 phút)

1. Vào https://vercel.com → **Sign up / Log in** → chọn **Continue with GitHub** (đăng nhập bằng GitHub cho tiện).
2. Bấm **Add New… → Project**.
3. Tìm repo `ffm-hub` (hoặc tên bạn đặt) → bấm **Import**.
4. Ở màn cấu hình:
   - **Framework Preset**: chọn **Other**.
   - Các mục khác để trống/mặc định.
5. Bấm **Deploy**. Đợi ~1 phút → hiện màn "Congratulations".
6. Bấm **Continue to Dashboard** → thấy đường link dạng `https://ffm-hub-xxxx.vercel.app`. **Đây là link app của bạn.**

---

## PHẦN 5 — Khai báo link cho Supabase (2 phút, bắt buộc để đăng nhập chạy)

1. Copy link Vercel ở trên (vd `https://ffm-hub-xxxx.vercel.app`).
2. Supabase → **Authentication** → **URL Configuration**.
   - **Site URL**: dán link vào.
   - **Redirect URLs**: bấm **Add URL**, dán link vào (thêm cả dạng có `/` cuối cũng được).
   - Bấm **Save**.

Bây giờ mở link Vercel → bạn sẽ thấy màn Đăng nhập/Đăng ký. Làm **Phần 2b** để tự nâng mình thành Admin.

---

## PHẦN 6 — Cài app vào máy/điện thoại như app thật (PWA)

- **Máy tính (Chrome/Edge):** mở link → nhìn cuối thanh địa chỉ có biểu tượng **⊕ (Cài đặt / Install)** → bấm → **Install**. App có icon riêng trên desktop.
- **Android (Chrome):** mở link → menu **⋮** → **Cài ứng dụng / Add to Home screen**.
- **iPhone/iPad (Safari):** mở link → nút **Chia sẻ** (ô vuông mũi tên) → **Thêm vào Màn hình chính**.

> Nút cài chỉ hiện khi mở qua link **https** của Vercel (mở file trong máy sẽ không có).

---

## PHẦN 7 — Kiểm tra app chạy đúng (checklist 5 phút)

1. Đăng ký 1 tài khoản test (email khác) → thấy màn **"Tài khoản đang chờ duyệt"**. ✅
2. Đăng nhập bằng tài khoản Admin của bạn → vào **Phân quyền** → duyệt tài khoản test, gán Vai trò + "Seller cũ" → bấm Duyệt. ✅
3. Đăng nhập lại bằng tài khoản test → chỉ thấy đúng phần được cấp quyền. ✅
4. Vào **Import dữ liệu** → thử 1 file → kiểm số đơn + ngày hiển thị đúng. ✅
5. Mở 1 đơn của người khác → bấm **🤝 Nhận hỗ trợ 24h** → sửa được phần Seller. ✅

Chạy hết 5 mục không lỗi = app đạt yêu cầu.

---

## PHẦN 8 — Sau này muốn sửa app thì làm gì?

1. Sửa file (vd `index.html`) trong thư mục `ffm-hub`.
2. Mở **GitHub Desktop** → gõ mô tả → **Commit to main** → **Push origin**.
3. Vercel tự cập nhật sau ~1 phút. Mở lại app là thấy bản mới.

---

## PHẦN 9 — Lỗi thường gặp & cách xử

- **Run SQL ra chữ đỏ "relation ... does not exist"** → project chưa có bảng gốc: đảm bảo đã chạy **cả** `supabase-setup.sql` (không bỏ đoạn nào).
- **Đăng nhập xong trắng trang / mất quyền** → chưa chạy hết `supabase-setup.sql` (phần vá RLS nằm ở cuối file). Chạy lại cả file.
- **Đăng nhập báo lỗi redirect** → chưa làm Phần 5 (khai báo Site URL / Redirect URLs).
- **Không thấy nút Cài đặt (PWA)** → phải mở qua link https của Vercel, không phải mở file.
- **Vercel deploy trắng trang** → kiểm tra khi Import đã chọn Framework = **Other** chưa.

Vướng ở đâu, chụp màn hình hoặc copy dòng lỗi gửi tôi, tôi chỉ tiếp.
