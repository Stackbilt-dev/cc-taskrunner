#!/usr/bin/env bash
# deploy.sh — Release pipeline for cc-taskrunner
#
# Stackbilt standard deploy pipeline (Tier 1), adapted for CLI tools.
# Validates the repo, runs checks, tags a release version.
#
# Usage:
#   ./scripts/deploy.sh              # Full release pipeline
#   ./scripts/deploy.sh --dry-run    # Validate only, no tag
#   ./scripts/deploy.sh --force      # Skip changelog verification
#
# The version is read from CHANGELOG.md (latest ## [x.y.z] heading).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=false
FORCE=false

# ─── Parse args ──────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --force)    FORCE=true; shift ;;
    *)          echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ─── Helpers ─────────────────────────────────────────────────

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $*" >&2; }

PASS=0
FAIL=0

check_pass() { ok "$1"; PASS=$((PASS + 1)); }
check_fail() { fail "$1"; FAIL=$((FAIL + 1)); }

# ─── Step 0: Read version from CHANGELOG ─────────────────────

cd "$PROJECT_ROOT"

log "cc-taskrunner release pipeline starting"

if [[ ! -f CHANGELOG.md ]]; then
  fail "CHANGELOG.md not found"
  exit 1
fi

VERSION=$(grep -m1 -oP '## \[\K[0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md || true)

if [[ -z "$VERSION" ]]; then
  fail "Could not parse version from CHANGELOG.md (expected ## [x.y.z] heading)"
  exit 1
fi

log "Version: v${VERSION}"

# ─── Step 1: Check for uncommitted changes ────────────────────

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  check_fail "Uncommitted changes detected (git status not clean)"
  git status --short
else
  check_pass "Working tree clean"
fi

# ─── Step 2: Verify CHANGELOG has content for this version ────

if [[ "$FORCE" != "true" ]]; then
  # Check that the version heading has at least one subsection
  CHANGELOG_ENTRY=$(sed -n "/^## \[${VERSION}\]/,/^## \[/p" CHANGELOG.md | head -20)
  if echo "$CHANGELOG_ENTRY" | grep -q "^### "; then
    check_pass "CHANGELOG.md has entry for v${VERSION}"
  else
    check_fail "CHANGELOG.md entry for v${VERSION} has no subsections (### Added, ### Fixed, etc.)"
  fi
else
  log "Skipping changelog verification (--force)"
fi

# ─── Step 3: Check for existing tag ───────────────────────────

if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  check_fail "Tag v${VERSION} already exists"
else
  check_pass "Tag v${VERSION} is available"
fi

# ─── Step 4: Run shellcheck on .sh files (if available) ───────

if command -v shellcheck &>/dev/null; then
  log "Running shellcheck..."
  SH_FILES=$(find "$PROJECT_ROOT" -name '*.sh' -not -path '*/node_modules/*' -not -path '*/.git/*')
  SC_FAIL=0
  for f in $SH_FILES; do
    if ! shellcheck -S warning "$f" 2>&1; then
      SC_FAIL=$((SC_FAIL + 1))
    fi
  done
  if [[ $SC_FAIL -eq 0 ]]; then
    check_pass "shellcheck passed on all .sh files"
  else
    check_fail "shellcheck reported issues in ${SC_FAIL} file(s)"
  fi
else
  log "shellcheck not installed — skipping (install: apt install shellcheck)"
fi

# ─── Step 5: Verify scripts are executable ────────────────────

NON_EXEC=0
for f in "$PROJECT_ROOT"/taskrunner.sh "$PROJECT_ROOT"/hooks/*.sh "$PROJECT_ROOT"/scripts/*.sh; do
  if [[ -f "$f" && ! -x "$f" ]]; then
    fail "Not executable: ${f#$PROJECT_ROOT/}"
    NON_EXEC=$((NON_EXEC + 1))
  fi
done
if [[ $NON_EXEC -eq 0 ]]; then
  check_pass "All .sh files are executable"
else
  check_fail "${NON_EXEC} script(s) not executable"
fi

# ─── Results ──────────────────────────────────────────────────

echo ""
log "Checks: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
  fail "Release blocked — fix issues above"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "(dry-run mode — this is informational)"
  fi
  exit 1
fi

# ─── Step 6: Tag the release ─────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
  log "(dry-run mode — would create tag v${VERSION})"
  ok "Dry run passed — ready to release v${VERSION}"
  exit 0
fi

log "Creating tag v${VERSION}..."
git tag -a "v${VERSION}" -m "Release v${VERSION}"
ok "Tagged v${VERSION}"

log ""
log "Release v${VERSION} tagged locally."
log "To publish: git push origin v${VERSION}"
log "Release pipeline complete"
