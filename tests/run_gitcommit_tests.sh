#!/bin/bash
#
# Pins the git command contract GitCommitManager depends on.
#
# The manager itself is @MainActor and Defaults-backed, so it cannot be compiled
# standalone the way FuzzyMatcher and ClaudeLimitParser can. What is testable —
# and what would actually break — is the behaviour of the exact git invocations
# it makes, against real repositories in real states. Each case below builds the
# state and asserts what the manager checks for.

set -u
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Keep the harness away from the user's identity and hooks.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0
git config --global user.email "harness@example.invalid"
git config --global user.name "Harness"
git config --global init.defaultBranch main
git config --global commit.gpgsign false

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $name"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

newrepo() {
  local dir="$TMP/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  echo seed > "$dir/seed.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "seed"
  echo "$dir"
}

# --- 1. a normal repo is recognised as a work tree -------------------------
R=$(newrepo normal)
check "is-inside-work-tree on a repo" "true" \
  "$(git -C "$R" rev-parse --is-inside-work-tree 2>/dev/null)"

# --- 2. a plain directory is not ------------------------------------------
mkdir -p "$TMP/plain"
git -C "$TMP/plain" rev-parse --is-inside-work-tree >/dev/null 2>&1
check "is-inside-work-tree outside a repo exits non-zero" "1" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# --- 3. branch name on a normal repo --------------------------------------
check "symbolic-ref gives the branch" "main" \
  "$(git -C "$R" symbolic-ref --short -q HEAD)"

# --- 4. empty commit succeeds and advances HEAD ---------------------------
BEFORE=$(git -C "$R" rev-parse HEAD)
git -C "$R" commit --allow-empty -qm "chore: daily checkpoint 2026-08-28"
AFTER=$(git -C "$R" rev-parse HEAD)
check "--allow-empty creates a commit" "different" \
  "$([ "$BEFORE" != "$AFTER" ] && echo different || echo same)"

# --- 5. the empty commit really is empty ----------------------------------
check "empty commit changes no files" "0" \
  "$(git -C "$R" diff --name-only "$BEFORE" "$AFTER" | wc -l | tr -d ' ')"

# --- 6. the message is stored verbatim ------------------------------------
check "commit message round-trips" "chore: daily checkpoint 2026-08-28" \
  "$(git -C "$R" log -1 --pretty=%s)"

# --- 7. no co-author trailer is added -------------------------------------
check "no co-author trailer" "0" \
  "$(git -C "$R" log -1 --pretty=%B | grep -ci 'co-authored-by' | tr -d ' ')"

# --- 8. detached HEAD is detected -----------------------------------------
D=$(newrepo detached)
git -C "$D" commit --allow-empty -qm second
git -C "$D" checkout -q --detach HEAD~1
git -C "$D" symbolic-ref --short -q HEAD >/dev/null 2>&1
check "symbolic-ref exits non-zero on detached HEAD" "1" \
  "$([ $? -ne 0 ] && echo 1 || echo 0)"

# --- 9. mid-merge is detectable by MERGE_HEAD -----------------------------
M=$(newrepo merging)
git -C "$M" checkout -qb other
echo other > "$M/conflict.txt"
git -C "$M" add -A && git -C "$M" commit -qm other
git -C "$M" checkout -q main
echo main > "$M/conflict.txt"
git -C "$M" add -A && git -C "$M" commit -qm main
git -C "$M" merge other -q >/dev/null 2>&1
GITDIR=$(git -C "$M" rev-parse --git-dir)
check "MERGE_HEAD exists during a conflicted merge" "yes" \
  "$([ -f "$M/$GITDIR/MERGE_HEAD" ] && echo yes || echo no)"

# --- 10. rev-parse --git-dir is relative inside a normal repo -------------
# The manager joins it onto the repo path when it is not absolute; if git ever
# started returning an absolute path that join would produce nonsense, so both
# shapes are handled. This pins which one is actually returned today.
check "git-dir is the relative .git" ".git" \
  "$(git -C "$R" rev-parse --git-dir)"

# --- 11. status --porcelain is empty on a clean tree ----------------------
check "clean tree reports nothing" "0" \
  "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')"

# --- 12. and non-empty with an untracked file ----------------------------
echo dirty > "$R/dirty.txt"
check "untracked file shows in porcelain" "1" \
  "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')"

# --- 13. add -A then commit picks it up ----------------------------------
git -C "$R" add -A
git -C "$R" commit -qm "with changes"
check "staged change is committed" "dirty.txt" \
  "$(git -C "$R" show --name-only --pretty=format: HEAD | tr -d '\n')"

# --- 14. GIT_TERMINAL_PROMPT=0 makes an unreachable push fail, not hang ---
P=$(newrepo pushless)
git -C "$P" remote add origin "https://127.0.0.1:1/nope.git"
START=$(date +%s)
GIT_TERMINAL_PROMPT=0 git -C "$P" push origin main >/dev/null 2>&1
RC=$?
ELAPSED=$(( $(date +%s) - START ))
check "push to an unreachable remote fails" "1" "$([ $RC -ne 0 ] && echo 1 || echo 0)"
check "and fails quickly rather than hanging" "1" "$([ $ELAPSED -lt 30 ] && echo 1 || echo 0)"

# --- 15. a repo with no commits at all still accepts an empty commit ------
E="$TMP/empty"; mkdir -p "$E"; git -C "$E" init -q
git -C "$E" commit --allow-empty -qm "first" >/dev/null 2>&1
check "empty commit works on a fresh repo" "1" \
  "$(git -C "$E" rev-list --count HEAD 2>/dev/null)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
