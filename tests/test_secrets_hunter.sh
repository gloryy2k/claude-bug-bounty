#!/bin/bash
# =============================================================================
# Tests for tools/secrets_hunter.sh
# Usage: bash tests/test_secrets_hunter.sh
#
# QA-10 (test/qa10-tool-capability-registry@0c23987) flagged that --include-paths
# only ever reached trufflehog -- noseyparker/gitleaks ran unrestricted over the
# whole repo even when the caller declared a path-scoped secrets scan. These
# tests stub all three binaries on PATH and assert noseyparker/gitleaks refuse
# to run (fail closed) once INCLUDE_PATHS is set, and still run normally
# without it.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_HUNTER="$SCRIPT_DIR/tools/secrets_hunter.sh"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; ((PASS++)) || true; }
fail() { echo "  FAIL: $1"; ((FAIL++)) || true; }

echo "============================================="
echo "  secrets_hunter.sh tests"
echo "============================================="

WORK="$(mktemp -d)"
STUBS="$WORK/stubs"
mkdir -p "$STUBS" "$WORK/repo"
trap 'rm -rf "$WORK"' EXIT

# Fake trufflehog/noseyparker/gitleaks: just prove they were invoked by touching a marker file.
cat > "$STUBS/trufflehog" <<'EOF'
#!/bin/bash
touch "$SECRETS_HUNTER_TEST_MARKERS/trufflehog.ran"
echo '{}'
EOF
cat > "$STUBS/noseyparker" <<'EOF'
#!/bin/bash
touch "$SECRETS_HUNTER_TEST_MARKERS/noseyparker.ran"
exit 0
EOF
cat > "$STUBS/gitleaks" <<'EOF'
#!/bin/bash
touch "$SECRETS_HUNTER_TEST_MARKERS/gitleaks.ran"
exit 0
EOF
chmod +x "$STUBS/trufflehog" "$STUBS/noseyparker" "$STUBS/gitleaks"

run_hunter() {
    local out="$1"; shift
    MARKERS="$WORK/markers_$out"
    mkdir -p "$MARKERS"
    SECRETS_HUNTER_TEST_MARKERS="$MARKERS" PATH="$STUBS:$PATH" \
        bash "$SECRETS_HUNTER" --git "$WORK/repo" --out "$WORK/out_$out" "$@" >"$WORK/log_$out" 2>&1
}

echo ""
echo "[Test 1] bash -n syntax check"
if bash -n "$SECRETS_HUNTER" 2>/dev/null; then
    pass "No syntax errors"
else
    fail "Syntax errors detected"
fi

echo ""
echo "[Test 2] Without --include-paths, noseyparker and gitleaks both run"
run_hunter plain
if [ -f "$WORK/markers_plain/noseyparker.ran" ] && [ -f "$WORK/markers_plain/gitleaks.ran" ]; then
    pass "noseyparker and gitleaks both ran"
else
    fail "expected both noseyparker and gitleaks to run without --include-paths"
fi

echo ""
echo "[Test 3] With --include-paths, noseyparker and gitleaks are skipped (fail closed)"
echo "src/" > "$WORK/include_paths.txt"
run_hunter scoped --include-paths "$WORK/include_paths.txt"
if [ -f "$WORK/markers_scoped/noseyparker.ran" ] || [ -f "$WORK/markers_scoped/gitleaks.ran" ]; then
    fail "noseyparker/gitleaks must not run against an unscoped target when scope is path-restricted"
else
    pass "noseyparker and gitleaks were skipped"
fi

echo ""
echo "[Test 4] With --include-paths, trufflehog still runs (it honors the restriction itself)"
if [ -f "$WORK/markers_scoped/trufflehog.ran" ]; then
    pass "trufflehog still ran"
else
    fail "trufflehog should still run -- it applies --include-paths itself"
fi

echo ""
echo "[Test 5] Skip is logged so it's visible in scan output, not silent"
if grep -q "noseyparker skipped" "$WORK/log_scoped" && grep -q "gitleaks skipped" "$WORK/log_scoped"; then
    pass "skip reason logged for both tools"
else
    fail "expected a logged skip reason for noseyparker and gitleaks"
fi

echo ""
echo "============================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================="

[ "$FAIL" -eq 0 ] || exit 1
