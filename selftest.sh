#!/bin/sh
set -e

# ── Self-test suite for codex-installer.sh ────────────────────────────────
# Runs install / uninstall / force-reinstall / pipe-install rounds against
# a temporary INSTALL_DIR so it never touches the real /usr/local/bin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$SCRIPT_DIR/codex-installer.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  RED=''; GREEN=''; BOLD=''; DIM=''; NC=''
fi

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf "${GREEN}  PASS${NC}  %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "${RED}  FAIL${NC}  %s\n" "$1"; }

run_installer() {
  INSTALL_DIR="$TEST_DIR" "$INSTALLER" "$@"
}

assert_file_exists() {
  [ -f "$1" ] && return 0
  return 1
}

assert_file_missing() {
  [ ! -f "$1" ] && return 0
  return 1
}

# ── Separator ──────────────────────────────────────────────────────────────
section() {
  printf "\n${BOLD}── %s ──${NC}\n" "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
section "1. --help output"

output=$(run_installer --help 2>&1)

if printf '%s' "$output" | grep -q "codex-installer.sh"; then
  pass "Usage line shows correct script name"
else
  fail "Usage line missing script name"
fi

if printf '%s' "$output" | grep -q "install.*Install or update"; then
  pass "Help lists install command"
else
  fail "Help missing install command"
fi

if printf '%s' "$output" | grep -q "uninstall.*Remove"; then
  pass "Help lists uninstall command"
else
  fail "Help missing uninstall command"
fi

if printf '%s' "$output" | grep -q "update-wrapper"; then
  pass "Help lists update-wrapper command"
else
  fail "Help missing update-wrapper command"
fi

if printf '%s' "$output" | grep -q "INSTALL_DIR"; then
  pass "Help documents INSTALL_DIR env var"
else
  fail "Help missing INSTALL_DIR documentation"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "2. Fresh install (--yes)"

run_installer install --yes

if assert_file_exists "$TEST_DIR/codex-real"; then
  pass "codex-real binary installed"
else
  fail "codex-real binary missing after install"
fi

if assert_file_exists "$TEST_DIR/codex"; then
  pass "codex wrapper installed"
else
  fail "codex wrapper missing after install"
fi

if [ -x "$TEST_DIR/codex-real" ]; then
  pass "codex-real is executable"
else
  fail "codex-real is not executable"
fi

if [ -x "$TEST_DIR/codex" ]; then
  pass "codex wrapper is executable"
else
  fail "codex wrapper is not executable"
fi

version=$("$TEST_DIR/codex-real" --version 2>/dev/null | awk '{print $NF}')
if [ -n "$version" ]; then
  pass "codex-real reports version: $version"
else
  fail "codex-real --version returned nothing"
fi

if head -1 "$TEST_DIR/codex" | grep -q '^#!/bin/sh'; then
  pass "Wrapper starts with #!/bin/sh shebang"
else
  fail "Wrapper has wrong or missing shebang"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "3. Already up to date (no --force)"

output=$(run_installer install --yes 2>&1)

if printf '%s' "$output" | grep -q "Already up to date"; then
  pass "Short-circuits when already up to date"
else
  fail "Did not detect existing up-to-date install"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "4. Force reinstall (--force --yes)"

output=$(run_installer install --force --yes 2>&1)

if printf '%s' "$output" | grep -q "Re-install"; then
  pass "Shows 'Re-install' action with --force"
else
  fail "Missing 'Re-install' in --force output"
fi

if printf '%s' "$output" | grep -qi "re-installing because --force"; then
  pass "Explains --force reason"
else
  fail "Missing --force explanation"
fi

if assert_file_exists "$TEST_DIR/codex-real"; then
  pass "codex-real still present after force reinstall"
else
  fail "codex-real missing after force reinstall"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "5. Wrapper passthrough to codex-real"

# The installed wrapper ($TEST_DIR/codex) should exec through to codex-real
# for any command that isn't install/uninstall/update-wrapper.
wrapper_ver=$("$TEST_DIR/codex" --version 2>&1 || true)
real_ver=$("$TEST_DIR/codex-real" --version 2>&1)

if [ -n "$wrapper_ver" ] && [ "$wrapper_ver" = "$real_ver" ]; then
  pass "codex --version matches codex-real --version ($real_ver)"
else
  fail "codex --version ('$wrapper_ver') != codex-real --version ('$real_ver')"
fi

wrapper_help=$("$TEST_DIR/codex" --help 2>&1 || true)

if printf '%s' "$wrapper_help" | grep -qi "codex"; then
  pass "codex --help returns real CLI help"
else
  fail "codex --help did not return real CLI help"
fi

# The wrapper help should NOT be the installer help (no "install" command listing)
if ! printf '%s' "$wrapper_help" | grep -q "update-wrapper"; then
  pass "Wrapper passthrough does not show installer usage"
else
  fail "Wrapper passthrough leaks installer usage"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "6. Uninstall (--yes)"

run_installer uninstall --yes

if assert_file_missing "$TEST_DIR/codex-real"; then
  pass "codex-real removed"
else
  fail "codex-real still present after uninstall"
fi

if assert_file_missing "$TEST_DIR/codex"; then
  pass "codex wrapper removed"
else
  fail "codex wrapper still present after uninstall"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "7. Uninstall when not installed"

output=$(run_installer uninstall --yes 2>&1)

if printf '%s' "$output" | grep -q "does not appear to be installed"; then
  pass "Warns when nothing to uninstall"
else
  fail "Missing 'not installed' warning"
fi

# ═══════════════════════════════════════════════════════════════════════════
section "8. Pipe install (cat | sh)"

WRAPPER_RAW_URL="file://$INSTALLER" \
  cat "$INSTALLER" | INSTALL_DIR="$TEST_DIR" WRAPPER_RAW_URL="file://$INSTALLER" sh

if assert_file_exists "$TEST_DIR/codex-real"; then
  pass "codex-real installed via pipe"
else
  fail "codex-real missing after pipe install"
fi

if assert_file_exists "$TEST_DIR/codex"; then
  pass "codex wrapper installed via pipe"
else
  fail "codex wrapper missing after pipe install"
fi

if head -1 "$TEST_DIR/codex" | grep -q '^#!/bin/sh'; then
  pass "Pipe-installed wrapper has valid shebang"
else
  fail "Pipe-installed wrapper has wrong shebang"
fi

# Verify the wrapper is readable and executable by the current user.
if [ -r "$TEST_DIR/codex" ] && [ -x "$TEST_DIR/codex" ]; then
  perms=$(stat -c '%a' "$TEST_DIR/codex" 2>/dev/null || stat -f '%Lp' "$TEST_DIR/codex" 2>/dev/null)
  pass "Wrapper is readable+executable by current user (mode $perms)"
else
  fail "Wrapper is not readable+executable by current user"
fi

# cleanup from pipe test
run_installer uninstall --yes >/dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════════
section "9. Bad arguments"

if ! run_installer --bogus 2>/dev/null; then
  pass "Rejects unknown flag"
else
  fail "Accepted unknown flag without error"
fi

# ═══════════════════════════════════════════════════════════════════════════
printf "\n${BOLD}════════════════════════════════════════${NC}\n"
TOTAL=$((PASS + FAIL))
printf "${BOLD}Results:${NC} %s/%s passed" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf ", ${RED}%s failed${NC}\n" "$FAIL"
  exit 1
else
  printf " ${GREEN}— all clear${NC}\n"
fi
