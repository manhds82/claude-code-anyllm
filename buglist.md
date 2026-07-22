# 📋 Buglist — claude-code-anyllm

> Tài liệu **sống**. Mọi bug / issue / vấn đề quan trọng đều log vào đây.
> Mỗi mục đủ 4 phần: **Tóm tắt · Chi tiết · Nguyên nhân · Cách fix** (fix xong thêm **Verify**).
>
> Cập nhật lần cuối: **2026-07-22**

---

## Bảng trạng thái

| # | Vấn đề | Mức | Trạng thái | Ngày |
|---|---|---|---|---|
| [B-04](#b-04) | ⭐ Workflow CI sai YAML (dòng cột 0 trong block `run: \|`) → GitHub Actions **chưa từng chạy** | 🔴 Cao | ✅ Fixed | 2026-07-22 |
| [B-03](#b-03) | ⭐ bash: `$( )` nuốt newline → từ 2 fallback provider trở lên sinh YAML hỏng | 🟠 Vừa | ✅ Fixed | 2026-07-22 |
| [B-02](#b-02) | Windows start-proxy nội suy API key vào chuỗi `-Command` (key có `'` sẽ hỏng/inject) | 🟠 Vừa | ✅ Fixed | 2026-07-22 |
| [B-01](#b-01) | ⭐ `.ps1` không có BOM + ký tự Unicode → PowerShell 5.1 lỗi parse trên locale non-UTF-8 | 🔴 Cao | ✅ Fixed | 2026-07-22 |

<!-- Mức: 🔴 Cao · 🟠 Vừa · 🟡 Thấp -->
<!-- Trạng thái: ✅ Fixed · ⏳ Đang xử lý · ⬜ Mở / CHƯA FIX · ⬜ Giới hạn đã biết -->

---

<a id="b-04"></a>
## B-04 — ⭐[COMMON] Workflow CI sai YAML nên GitHub Actions chưa từng chạy ✅ FIXED

**Tóm tắt.** `.github/workflows/claude-review.yml` **không parse được**, nên GitHub Actions bỏ qua
toàn bộ workflow — job review PR **chưa từng chạy lần nào**, và job test mới thêm cũng sẽ không chạy.

**Chi tiết.** `python -c "yaml.safe_load(...)"` → `ScannerError: could not find expected ':'` tại
dòng 104–106. Đó là `${REVIEW}` và `<sub>...</sub>` nằm ở **cột 0** bên trong block scalar `run: |`.

**Nguyên nhân.** Trong YAML, mọi dòng thuộc block scalar phải thụt lề sâu hơn key `run:`. Dòng ở cột
0 kết thúc block và bị hiểu là key YAML mới → sai cú pháp. Lỗi im lặng: Actions chỉ bỏ qua workflow.
Không thể sửa bằng cách thụt lề vào, vì khi đó markdown sẽ có 10 space đầu dòng → biến thành code block.

**Cách fix.** Dựng nội dung comment bằng `printf` vào `"$RUNNER_TEMP/review.md"` rồi
`gh pr comment --body-file` → mọi dòng nằm gọn trong block scalar, markdown vẫn sạch.

**Verify.** `yaml.safe_load` OK → `jobs: ['tests','review']`, matrix `[ubuntu-latest, windows-latest]`,
review gated `github.event_name == 'pull_request'`. Thêm guard `CI workflow YAML parses` vào policy-ci
(PS 35/35, bash 33/33 xanh) để không tái diễn.

---

<a id="b-03"></a>
## B-03 — ⭐[COMMON] bash `$( )` nuốt newline làm YAML fallback dính liền ✅ FIXED

**Tóm tắt.** Khi có **từ 2 fallback provider trở lên**, `start-claude.sh` sinh
`config/litellm_config.yaml` bị dính các entry vào cùng một dòng → YAML sai cú pháp → LiteLLM không
load được config (auto-failover chết).

**Chi tiết.** `start-claude.sh:384` (cũ):
`fallback_entries="${fallback_entries}$(printf '...\n')"`. Mô phỏng 2 provider cho ra
`...api_key: os.environ/K1  - model_name: ...` (entry 2 dính đuôi entry 1).

**Nguyên nhân.** Command substitution `$( )` trong POSIX shell **luôn cắt bỏ mọi newline ở cuối**.
Nên `\n` cuối của `printf` bị mất, các entry nối trực tiếp vào nhau. Bug chỉ lộ khi có ≥2 fallback
(1 fallback vẫn "may mắn" đúng vì block kế tiếp mở đầu bằng `\n`).

**Cách fix.** Nối thêm newline tường minh sau command substitution: `...)"$'\n'`, và bỏ `\n` thừa
trong format string.

**Verify.** Mô phỏng 2 provider sau fix → 2 block `- model_name:` tách dòng đúng chuẩn; PyYAML parse
config mẫu OK. `tests/run-tests.*` xanh (PS 34/34, bash 32/32).

---

<a id="b-02"></a>
## B-02 — Windows start-proxy nội suy API key vào chuỗi `-Command` ✅ FIXED

**Tóm tắt.** Trên Windows, `start-claude.ps1` và `toggle-brain.ps1` dựng chuỗi lệnh chứa
`` `$env:LLM_API_KEY = '$Key' `` rồi chạy qua `Start-Process powershell -Command`. Key chứa dấu nháy
đơn `'` sẽ làm hỏng chuỗi (proxy không start) và là lỗ hổng dạng command-injection.

**Chi tiết.** `start-claude.ps1:452`, `toggle-brain.ps1:373`. Đối chiếu: bản bash an toàn —
`LLM_API_KEY="$KEY" nohup "$LITELLM" ...` (start-claude.sh:415, toggle-brain.sh:254) truyền key qua
biến môi trường, KHÔNG nội suy vào chuỗi lệnh. Đây là điểm **lệch hành vi PS↔bash**.

**Nguyên nhân.** Nhánh PowerShell build command-string cho cửa sổ proxy mới và nhét key vào trong,
thay vì set env ở tiến trình cha rồi để tiến trình con kế thừa.

**Cách fix.** Set `$env:LLM_API_KEY = $Key` ở tiến trình **cha** trước `Start-Process` (tiến trình con
kế thừa bản sao env), bỏ hẳn dòng key khỏi command-string, và khôi phục env của phiên gọi trong khối
`finally` để không để sót key (tránh editor mở sau đó cũng thừa hưởng). **Xoá hẳn
`$fallbackKeyCmds`**: các key fallback vốn được ĐỌC TỪ env của tiến trình (dòng 366) nên con đã tự kế
thừa — việc nội suy chúng vừa không an toàn vừa thừa. Áp cho `start-claude.ps1` và `toggle-brain.ps1`.

**Verify.** `powershell -File start-claude.ps1 -Stop -Port 4999` và `toggle-brain.ps1 -Status` chạy
đúng; parse 0 lỗi. Regression test mới `key never interpolated into a command string` (red-team) chặn
tái diễn. Suite: PS 34/34, bash 32/32 xanh. Xem `docs/review-findings.md` B-02.

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
