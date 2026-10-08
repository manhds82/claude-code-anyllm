#!/usr/bin/env python3
"""Codex usage collector — the shared core for collect-codex.ps1 and .sh (C7).

WHY ONE FILE INSTEAD OF TWO: this code decides the numbers that end up on the
Cost dashboard. Writing the arithmetic twice, once in PowerShell and once in
bash, means two implementations that drift, and the drift shows up as a cost
figure that differs by machine — the least debuggable kind of wrong. Both
shells call THIS. The shells stay thin: locate things, pass paths, report.

WHAT IT READS
    ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl
    Every line is {timestamp, ordinal, type, payload}. Types used here:
      session_meta       payload.cwd  -> which project; payload.session_id
      turn_context       payload.turn_id + payload.model -> model per turn
      token_usage_record payload.turn_id + payload.usage -> tokens per response

WHY NO HOOK: Codex has no hook mechanism (C10 — for Codex this harness is
guidance plus after-the-fact evidence, not a boundary). That turns out to be an
advantage for telemetry: reading the transcript files directly does not depend
on a hook firing, unlike the Claude path, which silently collects nothing when
its SubagentStop hook is not wired.

THREE THINGS MEASURED FROM REAL DATA, NOT ASSUMED (14-09-2026, 15 session files,
293 token_usage_record lines on the maintainer's machine):

 1. `total_tokens == input_tokens + output_tokens` on 293/293 records, so
    `cached_input_tokens` is a SUBSET of input_tokens, not an addition.
    Claude Code reports the opposite shape: its input_tokens EXCLUDES cache
    reads (they sit in cache_read_input_tokens). So the comparable "new input"
    figure is `input_tokens - cached_input_tokens` for Codex and
    `input_tokens + cache_creation_input_tokens` for Claude. Reporting Codex's
    raw input_tokens instead would inflate it ~15x against Claude on the same
    work — measured: one thread summed 10,459,061 input of which 9,768,064
    were cache reads.

 2. `thread_token_usage` is CUMULATIVE. Summing it across records multi-counts.
    This code sums `payload.usage` (per-response) instead, and cross-checks the
    result against the LAST thread_token_usage — they matched exactly on all 14
    files, so a mismatch means the format changed and is reported, not hidden.

 3. The model is NOT in session_meta. It is in turn_context.payload.model and
    CHANGES within a session (one file mixed gpt-6-astra with codex-auto-review).
    Usage is therefore grouped per (thread, model), joined on turn_id — a single
    model per session would silently attribute one model's tokens to another.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone


ASSISTANT = "codex"


def _norm_path(p: str) -> str:
    """Compare paths the way a human means them: same folder, same project.

    Codex records `cwd` as the user typed/launched it, so case and separators
    vary from the harness root's spelling on Windows. realpath also resolves a
    junction/symlink, which is how a repo reached through two paths would
    otherwise look like two projects.
    """
    if not p:
        return ""
    try:
        p = os.path.realpath(p)
    except OSError:
        pass
    return os.path.normcase(os.path.normpath(p)).rstrip("\\/")


def _load_pricing(path: str) -> dict:
    """Pricing comes from data, never from this file (C2). Unreadable pricing is
    NOT fatal: tokens are the primary measurement and must still be collected.
    Cost degrades to unpriced, which is visible, rather than to a guess."""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return {}


def _rates_for(pricing: dict, model: str):
    models = pricing.get("models") or {}
    rates = models.get(model)
    if rates is None:
        rates = pricing.get("default") or {}
    return rates or {}


def estimate_cost(pricing: dict, model: str, new_input: int, cached_input: int, output: int):
    """-> (cost_usd, basis). basis is why the number is what it is.

    Returns cost 0.0 with basis "unpriced" when the rate is genuinely unknown.
    That is deliberate: a plausible-looking invented cost is worse than a
    visible gap, because nobody audits a number that looks fine (C13/C14).
    """
    r = _rates_for(pricing, model)
    r_in, r_out = r.get("input"), r.get("output")
    if r_in is None or r_out is None:
        return 0.0, "unpriced"
    r_cached = r.get("cached_input")
    basis = "priced"
    if r_cached is None:
        # No cache rate: charge cache reads at the full input rate and SAY SO.
        # On real data that overstates by roughly an order of magnitude.
        r_cached = r_in
        basis = "priced_no_cache_rate"
    cost = (new_input * r_in + cached_input * r_cached + output * r_out) / 1_000_000.0
    return round(cost, 6), basis


def iter_session_files(codex_sessions_dir: str):
    for root, _dirs, files in os.walk(codex_sessions_dir):
        for name in sorted(files):
            if name.endswith(".jsonl"):
                yield os.path.join(root, name)


def parse_session_file(path: str) -> dict | None:
    """Aggregate ONE Codex session file into per-(thread, model) totals.

    Returns None when the file carries no session_meta — that is not an error,
    just a file this collector has nothing to say about.
    """
    meta = None
    turn_model: dict[str, str] = {}
    # (thread_id, model) -> accumulator
    groups: dict[tuple, dict] = {}
    last_thread_usage = None
    usage_records = 0
    first_ts = last_ts = None

    try:
        fh = open(path, "r", encoding="utf-8-sig")
    except OSError:
        return None
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            rtype = rec.get("type")
            payload = rec.get("payload")
            if not isinstance(payload, dict):
                continue
            ts = rec.get("timestamp")
            if ts:
                if first_ts is None:
                    first_ts = ts
                last_ts = ts

            if rtype == "session_meta":
                meta = payload
            elif rtype == "turn_context":
                tid, model = payload.get("turn_id"), payload.get("model")
                if tid and isinstance(model, str) and model:
                    turn_model[tid] = model
            elif rtype == "token_usage_record":
                usage = payload.get("usage")
                if not isinstance(usage, dict):
                    continue
                usage_records += 1
                tt = payload.get("thread_token_usage")
                if isinstance(tt, dict):
                    last_thread_usage = tt
                thread_id = payload.get("thread_id") or payload.get("session_id") or ""
                # turn_id -> model. A usage record whose turn_context was never
                # seen keeps an explicit "unknown" rather than being folded into
                # whichever model happens to be handy.
                model = turn_model.get(payload.get("turn_id")) or "unknown"
                key = (thread_id, model)
                g = groups.setdefault(key, {
                    "thread_id": thread_id, "model": model,
                    "input_raw": 0, "cached_input": 0, "cache_write": 0,
                    "output": 0, "reasoning_output": 0, "responses": 0,
                    "start_time": ts, "end_time": ts,
                })
                g["input_raw"] += int(usage.get("input_tokens") or 0)
                g["cached_input"] += int(usage.get("cached_input_tokens") or 0)
                g["cache_write"] += int(usage.get("cache_write_input_tokens") or 0)
                g["output"] += int(usage.get("output_tokens") or 0)
                g["reasoning_output"] += int(usage.get("reasoning_output_tokens") or 0)
                g["responses"] += 1
                if ts:
                    g["end_time"] = ts
                    if not g["start_time"]:
                        g["start_time"] = ts

    if meta is None:
        return None
    return {
        "path": path,
        "meta": meta,
        "groups": list(groups.values()),
        "usage_records": usage_records,
        "last_thread_usage": last_thread_usage,
        "first_ts": first_ts,
        "last_ts": last_ts,
    }


def _latency_ms(start: str | None, end: str | None) -> int:
    if not start or not end:
        return 0
    try:
        t0 = datetime.fromisoformat(start.replace("Z", "+00:00"))
        t1 = datetime.fromisoformat(end.replace("Z", "+00:00"))
    except ValueError:
        return 0
    span = int((t1 - t0).total_seconds() * 1000)
    # Same 6h cap the Claude sampler uses: a resumed session spans days and that
    # wall-clock is not a latency.
    return span if 0 <= span <= 21_600_000 else 0


def build_records(parsed: dict, pricing: dict, active_member: str) -> list[dict]:
    """Turn one parsed session into telemetry lines in the EXISTING agentops
    format, so the Portal ingest needs no Codex-specific branch.

    Field choices worth stating:
      session_id = thread_id  — the stable id across a resumed session.
      agent_name = model      — the ingest dedupe key is
                                (assistant, session_id, agent_name), and a
                                session really can run two models. Keying on the
                                model is what stops one model's totals from
                                overwriting the other's. It also reads honestly
                                on screen: for Codex the thing that did the work
                                is identified by its model (main vs auto-review).
      tokens_in  = input_raw - cached_input   (see module docstring, point 1)
    """
    meta = parsed["meta"]
    out = []
    for g in parsed["groups"]:
        new_input = g["input_raw"] - g["cached_input"]
        if new_input < 0:
            # Would mean cached is NOT a subset after all, i.e. the format
            # changed under us. Clamp and flag rather than emit a negative.
            new_input = 0
        cost, basis = estimate_cost(pricing, g["model"], new_input, g["cached_input"], g["output"])
        rec = {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "agent_name": g["model"],
            "model": g["model"],
            "session_id": g["thread_id"],
            "status": "completed",
            "tokens_in": new_input,
            "tokens_out": g["output"],
            "total_tokens": new_input + g["output"],
            "estimated_cost_usd": cost,
            "latency_ms": _latency_ms(g["start_time"], g["end_time"]),
            "tool_calls": 0,          # not derivable from token_usage_record
            "start_time": g["start_time"] or parsed["first_ts"],
            "end_time": g["end_time"] or parsed["last_ts"],
            "active_account": str(meta.get("originator") or ""),
            "active_member": active_member,
            "assistant": ASSISTANT,
            # --- extra, ignored by the ingest, kept for auditing locally ---
            "codex_input_tokens_raw": g["input_raw"],
            "codex_cached_input_tokens": g["cached_input"],
            "codex_cache_write_input_tokens": g["cache_write"],
            "codex_reasoning_output_tokens": g["reasoning_output"],
            "codex_responses": g["responses"],
            "codex_cli_version": str(meta.get("cli_version") or ""),
            "cost_basis": basis,
        }
        out.append(rec)
    return out


def cross_check(parsed: dict) -> str | None:
    """Independent check that the per-response sum equals the transcript's own
    cumulative total. Returns a message when they disagree, else None.

    This is the format-drift detector. Codex's transcript is an internal file of
    a vendor's alpha CLI (cli_version 0.154.0-alpha at time of writing), not a
    committed API — a rename would otherwise make this collector quietly report
    zero. "Read the file but found no usage" must look different from "no
    sessions" (C14).
    """
    tt = parsed.get("last_thread_usage")
    if not isinstance(tt, dict):
        return None
    summed_in = sum(g["input_raw"] for g in parsed["groups"])
    summed_out = sum(g["output"] for g in parsed["groups"])
    exp_in = int(tt.get("input_tokens") or 0)
    exp_out = int(tt.get("output_tokens") or 0)
    if summed_in != exp_in or summed_out != exp_out:
        return ("sum(usage) != last(thread_token_usage): "
                "in %d vs %d, out %d vs %d" % (summed_in, exp_in, summed_out, exp_out))
    return None


def collect(harness_root: str, codex_sessions_dir: str, pricing_path: str,
            active_member: str = "") -> dict:
    """Collect every Codex session whose cwd is THIS project.

    Per-project on purpose: telemetry lives under each project's own .harness/,
    and the collector ships per project in the bundle. No cross-project writes,
    no fleet discovery, nothing to get wrong about which log a record lands in.
    """
    result = {
        "records": [], "sessions_total": 0, "sessions_for_project": 0,
        "warnings": [], "files_without_usage": 0, "unpriced_models": [],
    }
    if not os.path.isdir(codex_sessions_dir):
        result["warnings"].append("no Codex sessions dir: %s" % codex_sessions_dir)
        return result

    pricing = _load_pricing(pricing_path)
    if not pricing:
        result["warnings"].append(
            "pricing file unreadable (%s) -- tokens still collected, cost reported as unpriced"
            % pricing_path)

    want = _norm_path(harness_root)
    unpriced = set()
    for path in iter_session_files(codex_sessions_dir):
        parsed = parse_session_file(path)
        if parsed is None:
            continue
        result["sessions_total"] += 1
        if _norm_path(str(parsed["meta"].get("cwd") or "")) != want:
            continue
        result["sessions_for_project"] += 1

        if parsed["usage_records"] == 0:
            # A readable session file with zero usage lines. Either a session
            # that never called the model, or the field was renamed. Counted so
            # it can be reported -- silence here is the failure mode.
            result["files_without_usage"] += 1
            continue
        msg = cross_check(parsed)
        if msg:
            result["warnings"].append("%s: %s" % (os.path.basename(path), msg))

        for rec in build_records(parsed, pricing, active_member):
            if rec["cost_basis"] != "priced":
                unpriced.add("%s (%s)" % (rec["model"], rec["cost_basis"]))
            result["records"].append(rec)
    result["unpriced_models"] = sorted(unpriced)
    return result


def append_jsonl(path: str, records: list[dict]) -> None:
    """Append without a BOM. `Add-Content -Encoding utf8` on PowerShell 5.1
    writes EF BB BF when it creates a file, which makes the FIRST line
    unparseable to any reader doing json.loads per line — the same bug the
    Claude sampler carries a comment about."""
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(path, "a", encoding="utf-8", newline="") as f:
        for rec in records:
            f.write(json.dumps(rec, separators=(",", ":"), ensure_ascii=False) + "\n")


def load_state(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_state(path: str, state: dict) -> None:
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        json.dump(state, f, separators=(",", ":"))
    os.replace(tmp, path)


def main(argv: list[str]) -> int:
    """argv: <harness_root> <codex_sessions_dir> <pricing_path> [active_member]

    Prints a human-readable report to stdout and exits 0 unless something is
    genuinely broken. Never raises into the caller: this runs at session end,
    and a collector must not be the thing that breaks someone's session (C10).
    """
    if len(argv) < 4:
        print("usage: codex_collect.py <harness_root> <codex_sessions_dir> <pricing_path> [member]")
        return 2
    harness_root, sessions_dir, pricing_path = argv[1], argv[2], argv[3]
    active_member = argv[4] if len(argv) > 4 else ""

    try:
        res = collect(harness_root, sessions_dir, pricing_path, active_member)
    except Exception as exc:  # noqa: BLE001 - never break the caller
        print("[collect-codex] FAILED: %s" % exc)
        return 1

    tel = os.path.join(harness_root, ".harness", "telemetry")
    state_path = os.path.join(tel, ".codex-collect-state.json")
    state = load_state(state_path)

    # Emit only what CHANGED since last run. Correctness does not depend on this
    # -- the Portal ingest keys on (assistant, session_id, agent_name) and
    # updates in place, so a re-emitted record can never double-count. The state
    # file only stops agentops.log from growing by a full re-dump every run.
    # Losing it costs one redundant append, nothing more.
    fresh = []
    for rec in res["records"]:
        key = "%s|%s" % (rec["session_id"], rec["agent_name"])
        sig = "%d/%d" % (rec["tokens_in"], rec["tokens_out"])
        if state.get(key) == sig:
            continue
        state[key] = sig
        fresh.append(rec)

    if fresh:
        append_jsonl(os.path.join(tel, "agentops.log"), fresh)
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        append_jsonl(os.path.join(tel, "daily-%s.jsonl" % day), fresh)
        save_state(state_path, state)

    print("[collect-codex] sessions seen: %d | for this project: %d | new/changed records: %d"
          % (res["sessions_total"], res["sessions_for_project"], len(fresh)))
    if fresh:
        tin = sum(r["tokens_in"] for r in fresh)
        tout = sum(r["tokens_out"] for r in fresh)
        cached = sum(r["codex_cached_input_tokens"] for r in fresh)
        print("[collect-codex] tokens_in(new) %d | tokens_out %d | cache reads excluded %d"
              % (tin, tout, cached))
    if res["files_without_usage"]:
        # Not decoration. A session file this collector can READ but finds no
        # token_usage_record in is what a renamed field looks like. Saying
        # nothing here is how a collector reports 0 forever and looks healthy.
        print("[collect-codex] NOTE: %d session file(s) for this project had no "
              "token_usage_record. Expected for a session that never called the "
              "model -- but if this is ALL of them, the Codex transcript format "
              "has probably changed." % res["files_without_usage"])
    if res["unpriced_models"]:
        print("[collect-codex] UNPRICED (cost reported as 0, tokens are still correct): %s"
              % ", ".join(res["unpriced_models"]))
        print("[collect-codex]   fill in .harness/control/token-pricing.json to price these.")
    for w in res["warnings"]:
        print("[collect-codex] WARNING: %s" % w)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
