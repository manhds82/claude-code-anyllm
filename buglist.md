# 📋 Buglist — claude-code-anyllm

> Tài liệu **sống**. Mọi bug / issue / vấn đề quan trọng đều log vào đây.
> Mỗi mục đủ 4 phần: **Tóm tắt · Chi tiết · Nguyên nhân · Cách fix** (fix xong thêm **Verify**).
>
> Cập nhật lần cuối: **2026-07-22**

---

## Bảng trạng thái

| # | Vấn đề | Mức | Trạng thái | Ngày |
|---|---|---|---|---|
| [B-02](#b-02) | Windows start-proxy nội suy API key vào chuỗi `-Command` (key có `'` sẽ hỏng/inject) | 🟠 Vừa | ⬜ Mở | 2026-07-22 |
| [B-01](#b-01) | ⭐ `.ps1` không có BOM + ký tự Unicode → PowerShell 5.1 lỗi parse trên locale non-UTF-8 | 🔴 Cao | ✅ Fixed | 2026-07-22 |

<!-- Mức: 🔴 Cao · 🟠 Vừa · 🟡 Thấp -->
<!-- Trạng thái: ✅ Fixed · ⏳ Đang xử lý · ⬜ Mở / CHƯA FIX · ⬜ Giới hạn đã biết -->

---

<a id="b-02"></a>
## B-02 — Windows start-proxy nội suy API key vào chuỗi `-Command` ⬜ MỞ

**Tóm tắt.** Trên Windows, `start-claude.ps1` và `toggle-brain.ps1` dựng chuỗi lệnh chứa
`` `$env:LLM_API_KEY = '$Key' `` rồi chạy qua `Start-Process powershell -Command`. Key chứa dấu nháy
đơn `'` sẽ làm hỏng chuỗi (proxy không start) và là lỗ hổng dạng command-injection.

**Chi tiết.** `start-claude.ps1:452`, `toggle-brain.ps1:373`. Đối chiếu: bản bash an toàn —
`LLM_API_KEY="$KEY" nohup "$LITELLM" ...` (start-claude.sh:415, toggle-brain.sh:254) truyền key qua
biến môi trường, KHÔNG nội suy vào chuỗi lệnh. Đây là điểm **lệch hành vi PS↔bash**.

**Nguyên nhân.** Nhánh PowerShell build command-string cho cửa sổ proxy mới và nhét key vào trong,
thay vì set env ở tiến trình cha rồi để tiến trình con kế thừa.

**Cách fix (đề xuất, CHƯA làm).** Set `$env:LLM_API_KEY = $Key` (và các fallback key) ở tiến trình
cha TRƯỚC `Start-Process`; `Start-Process` tự kế thừa env → bỏ dòng key khỏi command-string. Chưa tự
sửa vì nhánh này còn ghép `$fallbackKeyCmds` (multi-provider fallback) cần đọc kỹ để không phá tính
năng. Rủi ro khai thác thấp (key là của chính người dùng). Xem `docs/review-findings.md` B-02.

---

<a id="b-01"></a>
## B-01 — ⭐[COMMON] `.ps1` không-BOM + Unicode làm PowerShell 5.1 lỗi parse ✅ FIXED

**Tóm tắt.** `start-claude.ps1` và `toggle-brain.ps1` **không chạy được trên Windows PowerShell 5.1**
ở máy có system locale không phải UTF-8 (ví dụ CP932 Nhật): PS báo lỗi parse (`token '[!]'`,
`thiếu ')'`, chuỗi không kết thúc) và thoát ngay, không mở proxy/editor.

**Chi tiết.** `powershell -File start-claude.ps1 -Stop` → parse error tại `start-claude.ps1:228`
(`Write-Host ("  [!]  ...")`). `bash -n` cho bản `.sh` PASS. Đọc file bằng UTF-8 rồi
`Parser::ParseInput` → **0 lỗi**. `head -c3` cho thấy file bắt đầu bằng `3c 23` (`<#`) — **không có
BOM**. `grep` thấy 2 dòng chứa ký tự non-ASCII (box-drawing `━` / emoji).

**Nguyên nhân.** Windows PowerShell 5.1 đọc script **không có BOM theo codepage ANSI của hệ thống**
(ở đây CP932), không phải UTF-8. Các byte UTF-8 nhiều-byte (`━`, emoji) bị giải mã sai → lệch
tokenizer → hàng loạt lỗi cú pháp giả. (pwsh 7+ mặc định UTF-8 nên không dính → dễ bị bỏ sót.)

**Cách fix.** Thêm **UTF-8 BOM** (`EF BB BF`) vào các `.ps1` có ký tự non-ASCII
(`start-claude.ps1`, `toggle-brain.ps1`); `setup-litellm.ps1` thuần ASCII nên không cần. Giữ nguyên
UI. Bổ sung test regression `tests/run-tests.ps1` / `.sh` (check "ps1 PS5.1-safe encoding": file có
non-ASCII **bắt buộc** có BOM). Cũng làm `profiles/claude.json` thuần ASCII (em-dash → `-`) để tránh
mojibake khi `Get-Content` đọc theo ANSI.

**Verify.** Sau fix: `powershell -File start-claude.ps1 -Stop -Port 4999` in ra
`==> Looking for the process holding port 4999 ...` (chạy đúng, exit 0). `toggle-brain.ps1 -Status`
in được header BRAIN STATUS. `tests/run-tests.ps1` = **32/32 PASS**, `tests/run-tests.sh` = **30/30
PASS**, cả hai gồm check encoding PS5.1-safe.

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
