# 📋 Buglist — <PROJECT>

> Tài liệu **sống**. Mọi bug / issue / vấn đề quan trọng đều log vào đây.
> Mỗi mục đủ 4 phần: **Tóm tắt · Chi tiết · Nguyên nhân · Cách fix** (fix xong thêm **Verify**).
>
> Cập nhật lần cuối: **<YYYY-MM-DD>**

---

## Bảng trạng thái

| # | Vấn đề | Mức | Trạng thái | Ngày |
|---|---|---|---|---|
| [B-01](#b-01) | (ví dụ) mô tả ngắn gọn vấn đề | 🟡 Thấp | ⬜ Mở | <YYYY-MM-DD> |

<!-- Mức: 🔴 Cao · 🟠 Vừa · 🟡 Thấp -->
<!-- Trạng thái: ✅ Fixed · ⏳ Đang xử lý · ⬜ Mở / CHƯA FIX · ⬜ Giới hạn đã biết -->

---

<a id="b-01"></a>
## B-01 — (ví dụ) tiêu đề bug ⬜ MỞ

**Tóm tắt.** Một câu mô tả hậu quả người dùng/hệ thống thấy được.

**Chi tiết.** Số liệu đo được, log, bước tái hiện. Ghi rõ đo ở đâu, khi nào.

**Nguyên nhân.** Root cause thật sự (không phải triệu chứng).

**Cách fix.** Thay đổi cụ thể (file, hàm, config). Nếu chưa làm, ghi rõ lý do/ROI.

**Verify.** (điền sau khi fix) Bằng chứng cụ thể — không viết "đã test OK".

---

## 🪲 Bẫy đã sập / suýt sập — đọc trước khi debug loại tương tự

| Bẫy | Biểu hiện | Cách tránh |
|---|---|---|
| (ví dụ) | | |

---

## Quy ước ghi buglist (BẮT BUỘC)

1. **Bug mới thêm vào đầu bảng trạng thái** + section chi tiết theo `B-<số>`.
2. Bắt buộc đủ 4 phần: **Tóm tắt · Chi tiết · Nguyên nhân · Cách fix**. Fix xong thêm **Verify**.
3. **Số liệu đo được > mô tả cảm tính.**
4. **AI PHẢI tự log**: bất cứ khi nào AI phát hiện bug hệ thống, HOẶC chính AI gây ra bug,
   AI phải ghi ngay vào file này TRƯỚC khi coi task là xong.
5. **Đánh dấu loại bug** ngay trong tiêu đề hoặc Tóm tắt:
   - `🤖` hoặc `(AI)` — bug do AI tự gây ra (để tách khỏi bug hệ thống có sẵn).
   - `⭐` hoặc `[COMMON]` — bug quan trọng / dễ tái diễn / đáng phổ biến cho dự án khác.
6. Bẫy/gotcha (không phải bug) ghi vào bảng "Bẫy đã sập".
