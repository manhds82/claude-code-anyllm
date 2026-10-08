# Constitution — AI Software Development Harness Toolkit

## Our Mission
Transform agentic coding from an individual utility into a governed enterprise capability — where every consequential action passes through identity, policy, evaluation, and audit.

## Operating Principles

1. **Policy-as-Code**: All governance rules are declared in YAML (Contract Plane), never hardcoded in scripts. YAML is the Single Source of Truth (SSOT).

2. **Defense-in-Depth**: Local hooks (PEP) provide first-line defense. Server-side enforcement (PDP at gateway) provides authoritative control for high-risk actions. We never claim "safe" when only local hooks are in place.

3. **Deny-by-Default for Side-Effects**: Any tool call that mutates state is denied unless explicitly permitted through an approved workflow DAG.

4. **Immutable Audit Trail**: Every decision and action is recorded in a hash-chain ledger. Tampering with history is detectable.

5. **Fail-Open Reads, Fail-Closed Writes**: Read operations continue during degradation; write/deploy/DB operations halt.

6. **Lowest Layer Sets the Ceiling**: We invest in the weakest H-layer first. A strong H2 doesn't compensate for a weak H4.

## Our Commitments

- We **formalize existing assets** — skills, tools, and workflows already proven in production become first-class citizens of the harness.
- We **do not build what we already have** — the harness wraps existing execution capability in control layers, not replaces it.
- We **do not promise false safety** — we document every layer's limits honestly.
- We **keep concepts portable** while implementing on Claude Code (`.claude/` native, Windows/PowerShell).

## Success Criteria

- Every code change produces an **Evidence Bundle**: requirement trace · design impact · code diff · test report · security scan · review verdict · approval (if risk ≥ medium) · cost/telemetry.
- The harness scores CASAN Level 4+ across all H-layers.
- A new project can be onboarded in under 30 minutes with full governance.

## Bug logging (BẮT BUỘC — M6)

- **Mọi bug đều phải log vào `buglist.md`** ở gốc dự án — bug hệ thống PHÁT HIỆN
  được, VÀ bug do **chính AI gây ra**. Log **trước khi** coi task là hoàn thành.
- Mỗi mục đủ 4 phần: **Tóm tắt · Chi tiết · Nguyên nhân · Cách fix** (thêm
  **Verify** sau khi fix). Số liệu đo được > mô tả cảm tính.
- Đánh dấu loại: `🤖`/`(AI)` cho bug AI tự gây; `⭐`/`[COMMON]` cho bug quan
  trọng / dễ tái diễn (sẽ nổi lên trang **Common Bug** của Portal).
- File này là tài liệu SỐNG; Portal ingest nó thành tab Bug List mỗi dự án +
  trang Common Bug toàn tổ chức. Không log = vi phạm governance.
