#!/usr/bin/env bash
# H1 Context Harness — build/refresh the pipeline-context pointer store (bash
# parity of harness-context-build.ps1). Turns casan-policies `context` into a
# real .harness/context/pipeline-context.yaml so sub-agents discover inputs
# without re-scanning. Refreshes only when missing or older than the TTL.
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
POLICY="$HARNESS_ROOT/.harness/control/casan-policies.yaml"
STORE="$HARNESS_ROOT/.harness/context/pipeline-context.yaml"
TTL_MIN=240

if [ -f "$POLICY" ]; then
    ps=$(grep -oE 'pointer_store:[[:space:]]*"?[^"[:space:]]+' "$POLICY" 2>/dev/null | sed -E 's/.*pointer_store:[[:space:]]*"?//' || true)
    [ -n "$ps" ] && STORE="$HARNESS_ROOT/$ps"
    ttl=$(grep -oE 'staleness_ttl_minutes:[[:space:]]*[0-9]+' "$POLICY" 2>/dev/null | grep -oE '[0-9]+' || true)
    [ -n "$ttl" ] && TTL_MIN="$ttl"
fi

# Staleness: skip if fresh.
if [ -f "$STORE" ]; then
    now=$(date +%s); mtime=$(date -r "$STORE" +%s 2>/dev/null || echo 0)
    age_min=$(( (now - mtime) / 60 ))
    if [ "$age_min" -lt "$TTL_MIN" ]; then
        echo "[context] pipeline-context.yaml fresh (${age_min}m < ${TTL_MIN}m) -- kept"
        exit 0
    fi
fi

# Read a YAML string-list under `<key>:` from the policy (C2 - discovery lives in
# config). Naive on purpose: the hook path must not need a YAML dependency.
yaml_list() {
    [ -f "$POLICY" ] || return 0
    # The key line may carry a trailing comment; an absent/empty list must not
    # fail the script (grep exits 1 on no match and pipefail would propagate).
    sed -nE "/^[[:space:]]*$1:[[:space:]]*(#.*)?\$/,/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:/p" "$POLICY" \
      | grep -E '^[[:space:]]*-[[:space:]]' \
      | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/[[:space:]]*#.*$//; s/^"//; s/"$//; s/^'\''//; s/'\''$//' \
      || true
}

# Scan exclusions, read from config (C2). The fallback is the shipped default
# rather than "exclude nothing": casan-policies.yaml is project-owned in
# bundle-ownership.yaml, so an upgraded project keeps its old copy and never
# receives this key -- and with an empty list the scan would start indexing
# node_modules and .git.
EXCLUDE_GLOBS=$(yaml_list "exclude_globs")
[ -n "$EXCLUDE_GLOBS" ] || EXCLUDE_GLOBS=$'node_modules\n.git\ndist\nbuild\n.harness\n.claude/worktrees\nvendor\n.venv'
IFS=$'\n' read -r -d '' -a EXCLUDE_ARR < <(printf '%s\0' "$EXCLUDE_GLOBS") || true

# An entry matches a path SEGMENT. Wrapping both sides in '/' is what keeps
# "build" from swallowing "rebuild-notes.md". The pattern is left UNQUOTED so a
# '*' in the config still globs, and nocasematch mirrors PowerShell's
# case-insensitive -like so both shells exclude the same files.
is_excluded() {
    local rel="/$1/" e g rc=1
    shopt -s nocasematch
    for e in ${EXCLUDE_ARR[@]+"${EXCLUDE_ARR[@]}"}; do
        g="${e#/}"; g="${g%/}"
        [ -n "$g" ] || continue
        case "$rel" in */$g/*) rc=0; break;; esac
    done
    shopt -u nocasematch
    return "$rc"
}
# Filtering in the shell, not via find -path: -ipath is not portable, and only a
# post-filter can apply the same case rules as the PowerShell side.
filter_excluded() {
    local line
    while IFS= read -r line; do
        if is_excluded "$line"; then continue; fi
        printf '%s\n' "$line"
    done
}

# Deterministic pointer discovery: an entry with no wildcard is an exact path
# taken when present (canonical wins); a wildcard entry globs recursively and the
# matches are SORTED so the chosen file cannot flip between runs.
find_first() {
    local p hit
    for p in "$@"; do
        case "$p" in
            *[*?]*)
                hit=$(find "$HARNESS_ROOT" -type f -iname "$p" 2>/dev/null \
                      | sed "s#^$HARNESS_ROOT/##" | filter_excluded \
                      | LC_ALL=C sort | head -1 || true)
                ;;
            *)
                if [ -f "$HARNESS_ROOT/$p" ]; then hit="$p"; else hit=""; fi
                ;;
        esac
        if [ -n "$hit" ]; then echo "$hit"; return; fi
    done
    echo ""
}

SRS_CANDIDATES=$(yaml_list "srs_candidates"); [ -n "$SRS_CANDIDATES" ] || SRS_CANDIDATES=$'SRS*.md\nsrs*.md\n*requirements*.md'
SPEC_CANDIDATES=$(yaml_list "spec_candidates"); [ -n "$SPEC_CANDIDATES" ] || SPEC_CANDIDATES=$'*spec*.md\nSPEC*.md\nopenapi*.y*ml'
IFS=$'\n' read -r -d '' -a SRS_ARR < <(printf '%s\0' "$SRS_CANDIDATES") || true
IFS=$'\n' read -r -d '' -a SPEC_ARR < <(printf '%s\0' "$SPEC_CANDIDATES") || true
SRS=$(find_first "${SRS_ARR[@]}")
SPEC=$(find_first "${SPEC_ARR[@]}")

# Look one level down as well as at the root.
#
# Root-only detection gives every MONOREPO the poison value ["unknown"], because
# its manifests live in subdirectories. That value fails H1-4 permanently and
# silently, and since this file is rebuilt on every SessionStart, filling it in
# by hand does not survive the next session.
#
# Bounded to depth 2: deep enough for the standard apps/<name>/ or <service>/
# layout, shallow enough that it never walks node_modules or a vendored tree.
_skip_dir() {
  case "$(basename "$1")" in
    node_modules|.git|.venv|venv|vendor|dist|build|__pycache__|.harness|.*) return 0;;
    *) return 1;;
  esac
}
_detect_in() {
  local d="$1"
  [ -f "$d/package.json" ] && STACK+=("node")
  { [ -f "$d/requirements.txt" ] || [ -f "$d/pyproject.toml" ]; } && STACK+=("python")
  [ -f "$d/go.mod" ] && STACK+=("go")
  [ -f "$d/pom.xml" ] && STACK+=("java")
  [ -f "$d/Cargo.toml" ] && STACK+=("rust")
  [ -f "$d/composer.json" ] && STACK+=("php")
  return 0
}

STACK=()
_detect_in "$HARNESS_ROOT"
for _d1 in "$HARNESS_ROOT"/*/; do
  [ -d "$_d1" ] || continue
  _skip_dir "${_d1%/}" && continue
  _detect_in "${_d1%/}"
  # One more level for the apps/<name>/ and packages/<name>/ shape, which puts
  # every manifest two directories down.
  for _d2 in "${_d1%/}"/*/; do
    [ -d "$_d2" ] || continue
    _skip_dir "${_d2%/}" && continue
    _detect_in "${_d2%/}"
  done
done
[ ${#STACK[@]} -eq 0 ] && STACK+=("unknown")
# de-dup
STACK=($(printf '%s\n' "${STACK[@]}" | awk '!seen[$0]++'))

ARTIFACTS=()
add_artifact() {
    local v="$1" e
    [ -n "$v" ] || return 0
    # `[ ... ] && return` would make the loop's last status non-zero and trip set -e.
    for e in ${ARTIFACTS[@]+"${ARTIFACTS[@]}"}; do
        if [ "$e" = "$v" ]; then return 0; fi
    done
    ARTIFACTS+=("$v")
}
# A glob match that is a directory contributes itself; a match that is a FILE
# contributes its parent dir -- that is what makes "*/__init__.py" name the
# Python package on layouts whose source dir is not called "src".
resolve_dirs() {
    local g="$1" m d
    ( cd "$HARNESS_ROOT" 2>/dev/null || exit 0
      for m in $g; do
          [ -e "$m" ] || continue
          if [ -d "$m" ]; then
              printf '%s\n' "${m%/}"
          else
              d=$(dirname "$m"); [ "$d" = "." ] || printf '%s\n' "$d"
          fi
      done ) | LC_ALL=C sort -u
}
ART_GLOBS=$(yaml_list "artifact_globs"); [ -n "$ART_GLOBS" ] || ART_GLOBS=$'docs\ntests\ncontracts\n.harness'
SRC_GLOBS=$(yaml_list "source_globs");   [ -n "$SRC_GLOBS" ]  || SRC_GLOBS=$'src\napp\nlib\n*/__init__.py'
while IFS= read -r g; do [ -n "$g" ] || continue; while IFS= read -r hit; do add_artifact "$hit"; done < <(resolve_dirs "$g"); done <<< "$SRC_GLOBS"
while IFS= read -r g; do [ -n "$g" ] || continue; while IFS= read -r hit; do add_artifact "$hit"; done < <(resolve_dirs "$g"); done <<< "$ART_GLOBS"

join_q() { local out=""; for x in "$@"; do out="$out\"$x\", "; done; echo "${out%, }"; }

mkdir -p "$(dirname "$STORE")"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    echo "# pipeline-context pointer store (H1) -- auto-built by harness-context-build."
    echo "# Sub-agents read this to discover inputs WITHOUT re-scanning the repo."
    echo "generated_at: \"$NOW\""
    echo "srs_path: \"$SRS\""
    echo "spec_path: \"$SPEC\""
    echo "tech_stack: [$(join_q "${STACK[@]}")]"
    echo "artifact_paths: [$(join_q "${ARTIFACTS[@]}")]"
} > "$STORE"

# The PS1 has always appended this; bash never did, so the two shells disagreed
# on the one line an operator reads to notice that no SRS/spec was found.
MISSING=""
[ -n "$SRS" ]  || MISSING="srs_path"
[ -n "$SPEC" ] || MISSING="${MISSING:+$MISSING,}spec_path"
echo "[context] built pipeline-context.yaml (stack=$(IFS=/; echo "${STACK[*]}"); artifacts=${#ARTIFACTS[@]})${MISSING:+ missing: $MISSING}"

# H1 RAG-lite — (re)build the retrieval index over context sources (best-effort).
RAG="$HARNESS_ROOT/.harness/scripts/lib/harness_rag.py"
if [ -f "$RAG" ] && command -v python3 >/dev/null 2>&1; then
    HARNESS_ROOT="$HARNESS_ROOT" python3 "$RAG" index --root "$HARNESS_ROOT" || true
fi
exit 0
