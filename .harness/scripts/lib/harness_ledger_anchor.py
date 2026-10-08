#!/usr/bin/env python3
"""Emit this project's ledger anchor as one JSON line (S-6).

C9 makes the chain tamper-EVIDENT: rewrite an entry and the next entry_hash
stops matching. What it cannot be, while the chain lives only in a file on the
dev machine, is tamper-RESISTANT -- whoever can edit one line can regenerate the
whole file, and a regenerated chain is internally perfect. Self-consistency
proves nothing about a chain someone could rewrite end to end.

So the shape of the chain is reported to somewhere the rewriter does not
control. This computes it; the Portal remembers it and compares the next one.

The anchor is deliberately tiny -- four fields, no entries -- because it rides
on every push and the whole point of S-3 was to stop shipping megabytes of
repetition.

Emitted, and why each one is needed:

  entry_count       a chain must grow. A shorter one was rebuilt or truncated.
  head_hash         the newest entry_hash: what the next push must extend.
  genesis_hash      identifies the SEGMENT. A new genesis with the same project
                    means the chain was restarted -- legitimately or not.
  prev_segment_head set by `evidence-ledger seal` in the new genesis. This is
                    what separates a lawful rotation from a rebuild: a seal
                    names the head it continues from, a rebuild cannot.

Prints nothing when there is no chain. An absent anchor is a gap the Portal can
see; a fabricated one would be the failure this whole mechanism exists to catch.
"""
import collections
import json
import os
import sys

# P1 1.5: how many of the newest entry hashes ride along. The Portal looks the
# head it anchored LAST time up in this window, so "ok" means "grew from where it
# was" and not merely "has more lines". 500 x 64 hex chars is ~32 KB per push.
RECENT_WINDOW = 500


def anchor(root):
    chain = os.path.join(root, ".harness", "ledger", "chain.jsonl")
    if not os.path.isfile(chain):
        return None

    count = 0
    first = None
    last = None
    recent = collections.deque(maxlen=RECENT_WINDOW)
    try:
        # utf-8-sig: some chains predate the BOM fix and still carry one.
        with open(chain, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    # A corrupt line is counted but cannot contribute a hash.
                    # Skipping it silently would let a tamperer shrink the chain
                    # by corrupting lines instead of deleting them.
                    count += 1
                    recent.append("")       # keeps the window aligned with chain positions
                    continue
                count += 1
                if first is None:
                    first = rec
                last = rec
                recent.append(str((rec or {}).get("entry_hash") or "") if isinstance(rec, dict) else "")
    except OSError:
        return None

    if count == 0:
        return None

    return {
        "entry_count": count,
        "head_hash": str((last or {}).get("entry_hash") or ""),
        "genesis_hash": str((first or {}).get("entry_hash") or ""),
        # Present only when this segment was started by a seal.
        "prev_segment_head": str((first or {}).get("prev_segment_head") or ""),
        # Oldest first; the last element is head_hash, so recent_hashes[i] is chain
        # position entry_count - len(recent_hashes) + i.
        "recent_hashes": list(recent),
    }


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    a = anchor(root)
    if a is None:
        return 0
    sys.stdout.write(json.dumps(a, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
