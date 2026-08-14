#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the crew-checkout write-guard (docs/crew-checkout-guard.md).
#
# bin/fm-crew-checkout-pretool-check.sh is the single decision owner: every
# harness (Claude via .claude/settings.json, Pi via the crew extension's
# tool_call block, and the rest as scoped follow-up) shells out to it, so this
# suite pins the decision through that executable interface with real git
# worktrees and no harness. It proves the deny/allow matrix, harness-output
# shaping, crew-worktree scoping (the inverse of the cd-guard: inert in the
# primary and secondmate homes, active only in a crew/scout linked worktree),
# the Pi integration form (--command with FM_ROOT_OVERRIDE pinning the crew
# worktree), the fail-open transport, the sibling-worktree case, and the
# end-to-end reach-over regression that proves the deny actually fires. Live
# per-harness block behavior (Pi's {block:true}, Claude's PreToolUse deny) is
# harness-dependent and proven separately; see docs/crew-checkout-guard.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-crew-checkout)

install_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-crew-checkout-pretool-check.sh" "$dir/bin/fm-crew-checkout-pretool-check.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  chmod +x "$dir/bin/fm-crew-checkout-pretool-check.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/, and
# a state/ dir so fm_primary_scope_matches recognizes it as a genuine primary
# home. The guard must be inert here (the inverse of the crew scope).
make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  mkdir -p "$dir/state" "$dir/data"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree - the shape bin/fm-spawn.sh hands a crewmate or
# scout. git-dir and git-common-dir differ, so the guard is active here.
make_child_worktree() {
  local base=$1 dir=$2 branch=$3
  git -C "$base" worktree add --quiet -b "$branch" "$dir"
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
PRIMARY=$(cd "$PRIMARY" && pwd -P)
WORKTREE=$(make_child_worktree "$PRIMARY" "$TMP_ROOT/crew-wt" fm/crew-guard-test)
WORKTREE=$(cd "$WORKTREE" && pwd -P)
SIBLING=$(make_child_worktree "$PRIMARY" "$TMP_ROOT/sibling-wt" fm/crew-guard-sibling)
SIBLING=$(cd "$SIBLING" && pwd -P)

# The script AS THE CREW SEES IT: invoked from inside the crew worktree's own
# bin/, so it resolves OWN = the crew worktree, exactly as Claude's
# "$CLAUDE_PROJECT_DIR"/bin/... invocation does.
CHECK="$WORKTREE/bin/fm-crew-checkout-pretool-check.sh"

# --- deny/allow decision matrix (all harness entry forms) ------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_KIND=()
MATRIX_VALUE=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_KIND+=("$3")
  MATRIX_VALUE+=("$4")
}

# DENY: reach-over into the primary checkout.
matrix_case D01 deny command "cd $PRIMARY"
matrix_case D02 deny command "cd $PRIMARY && git commit -am x"
matrix_case D03 deny command "cd $PRIMARY/bin"
matrix_case D04 deny command "pushd $PRIMARY"
matrix_case D05 deny command "git -C $PRIMARY commit -am x"
matrix_case D06 deny command "git -C $PRIMARY status"
matrix_case D07 deny command "git -C$PRIMARY log"
matrix_case D08 deny command "git --git-dir=$PRIMARY/.git --work-tree=$PRIMARY add -A"
matrix_case D09 deny command "X=1 cd $PRIMARY"
matrix_case D10 deny command "true && cd $PRIMARY"
matrix_case D11 deny command "echo hi; cd $PRIMARY"
matrix_case D12 deny command "cd -- $PRIMARY"
matrix_case D13 deny command "cd \"$PRIMARY\""
matrix_case D14 deny file "$PRIMARY/AGENTS.md"
matrix_case D15 deny file "$PRIMARY/bin/new-file.sh"
# DENY: reach-over into a sibling crew worktree.
matrix_case D16 deny command "cd $SIBLING"
matrix_case D17 deny file "$SIBLING/foo.txt"

# ALLOW: legitimate in-own-worktree work.
matrix_case A01 allow command "cd $WORKTREE/bin"
matrix_case A02 allow command "cd $WORKTREE"
matrix_case A03 allow command "git -C $WORKTREE commit -am x"
matrix_case A04 allow command "git commit -am x"
matrix_case A05 allow command "git log --oneline"
matrix_case A06 allow command "cd subdir"
matrix_case A07 allow command "cd .."
matrix_case A08 allow file "$WORKTREE/foo.txt"
matrix_case A09 allow file "$WORKTREE/bin/generated.sh"
# ALLOW: reads that merely mention the primary path (no cd/git target).
matrix_case A10 allow command "cat $PRIMARY/AGENTS.md"
matrix_case A11 allow command "grep -r foo $PRIMARY"
matrix_case A12 allow command "ls $PRIMARY/bin"
# ALLOW: paths outside any firstmate checkout.
matrix_case A13 allow command "cd /tmp"
matrix_case A14 allow file "/tmp/scratch.txt"
# ALLOW: a quoted cd string inside echo must not arm on the quoted word.
matrix_case A15 allow command "echo \"cd $PRIMARY\""

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 kind=$3 value=$4 entry=$5 out_file err_file rc payload
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry:$kind" in
    cli:command)
      "$CHECK" --command "$value" >"$out_file" 2>"$err_file"; rc=$?
      ;;
    cli:file)
      "$CHECK" --file "$value" >"$out_file" 2>"$err_file"; rc=$?
      ;;
    claude:command)
      "$CHECK" --claude --command "$value" >"$out_file" 2>"$err_file"; rc=$?
      ;;
    claude:file)
      "$CHECK" --claude --file "$value" >"$out_file" 2>"$err_file"; rc=$?
      ;;
    stdin-claude:command)
      payload=$(jq -cn --arg c "$value" '{tool_name:"Bash",tool_input:{command:$c}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"; rc=$?
      ;;
    stdin-claude:file)
      payload=$(jq -cn --arg f "$value" '{tool_name:"Write",tool_input:{file_path:$f}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"; rc=$?
      ;;
    stdin-grok:command)
      payload=$(jq -cn --arg c "$value" '{toolName:"run_terminal_command",toolInput:{command:$c}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"; rc=$?
      ;;
    stdin-grok:file)
      payload=$(jq -cn --arg f "$value" '{toolName:"edit_file",toolInput:{file_path:$f}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"; rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry:$kind"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[crew-cross-checkout-write\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the reason code on stderr: $(cat "$err_file")"
  case "$entry" in
    claude)
      [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
      ;;
    stdin-grok)
      jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
        || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
      ;;
  esac
}

test_decision_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in cli claude stdin-claude stdin-grok; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "${MATRIX_KIND[$i]}" "${MATRIX_VALUE[$i]}" "$entry"
    done
  done
  pass "crew-checkout matrix: ${#MATRIX_IDS[@]} cases x 4 harness entry forms, deny/allow all correct"
}

# --- reads are never denied even if a read tool is misconfigured onto it ----

test_readonly_tool_file_allowed() {
  local out rc tool payload
  for tool in Read Grep Glob NotebookRead; do
    payload=$(jq -cn --arg t "$tool" --arg f "$PRIMARY/AGENTS.md" '{tool_name:$t,tool_input:{file_path:$f}}')
    out=$(printf '%s' "$payload" | "$CHECK" 2>&1); rc=$?
    expect_code 0 "$rc" "a $tool payload naming a primary-checkout file must be allowed (reads are never denied)"
    [ -z "$out" ] || fail "$tool read produced output: $out"
  done
  pass "crew-checkout: read-only tools naming a primary-checkout path are always allowed"
}

# --- Pi integration form: --command with FM_ROOT_OVERRIDE pinning the crew ---

test_pi_integration_form() {
  # The Pi crew extension invokes the checker from the shared code root but pins
  # the crew worktree via FM_ROOT_OVERRIDE, because the extension file lives
  # outside the worktree. Invoke from the PRIMARY's bin (OWN would resolve to the
  # primary and go inert) but override OWN to the crew worktree, exactly as the
  # generated extension does: the reach-over must still deny.
  local out rc
  out=$(FM_ROOT_OVERRIDE="$WORKTREE" "$PRIMARY/bin/fm-crew-checkout-pretool-check.sh" --command "cd $PRIMARY && git commit -am x" 2>&1); rc=$?
  expect_code 2 "$rc" "Pi form (FM_ROOT_OVERRIDE=crew-worktree) must deny a reach-over into the primary"
  assert_contains "$out" '[crew-cross-checkout-write]' "Pi-form deny must carry the reason code"

  out=$(FM_ROOT_OVERRIDE="$WORKTREE" "$PRIMARY/bin/fm-crew-checkout-pretool-check.sh" --command "git commit -am x" 2>&1); rc=$?
  expect_code 0 "$rc" "Pi form must allow an in-worktree git commit"
  [ -z "$out" ] || fail "Pi-form in-worktree commit produced output: $out"

  # Without the override the same script call resolves OWN to the primary and is
  # correctly inert (this is why the extension MUST pass FM_ROOT_OVERRIDE).
  out=$("$PRIMARY/bin/fm-crew-checkout-pretool-check.sh" --command "cd $PRIMARY" 2>&1); rc=$?
  expect_code 0 "$rc" "without the crew-worktree override the guard is inert in the primary"
  pass "crew-checkout: Pi integration form denies reach-over and allows in-worktree work"
}

# --- scoping: inert everywhere that is not a crew worktree ------------------

test_inert_in_primary() {
  local out rc
  out=$("$PRIMARY/bin/fm-crew-checkout-pretool-check.sh" --claude --command "cd $SIBLING" 2>&1); rc=$?
  expect_code 0 "$rc" "guard must be inert in the primary session (only the cd-guard protects it)"
  [ -z "$out" ] || fail "guard produced output in the primary: $out"
  pass "crew-checkout: inert in the primary session (the inverse of the cd-guard)"
}

test_inert_in_secondmate_home() {
  local dir out rc
  dir="$TMP_ROOT/secondmate"
  make_primary_fixture "$dir" >/dev/null
  dir=$(cd "$dir" && pwd -P)
  printf 'sm-crew-1\n' > "$dir/.fm-secondmate-home"
  out=$("$dir/bin/fm-crew-checkout-pretool-check.sh" --claude --command "cd $PRIMARY" 2>&1); rc=$?
  expect_code 0 "$rc" "guard must be inert in a secondmate home (its own primary session)"
  [ -z "$out" ] || fail "guard produced output in a secondmate home: $out"
  pass "crew-checkout: inert in a secondmate home"
}

test_inert_when_not_firstmate_repo() {
  local dir out rc
  dir="$TMP_ROOT/not-fm"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" worktree add --quiet -b wt "$TMP_ROOT/not-fm-wt"
  install_scripts "$TMP_ROOT/not-fm-wt"   # bin/ + script but no AGENTS.md
  out=$("$TMP_ROOT/not-fm-wt/bin/fm-crew-checkout-pretool-check.sh" --claude --command "cd $dir" 2>&1); rc=$?
  expect_code 0 "$rc" "guard must be inert without AGENTS.md (not a firstmate checkout)"
  [ -z "$out" ] || fail "guard produced output outside a firstmate checkout: $out"
  pass "crew-checkout: inert in a non-firstmate worktree (no AGENTS.md)"
}

# --- fail-open transport ----------------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "crew-checkout: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "crew-checkout: fails open on unparseable stdin JSON"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc payload
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname basename cat printf sed tr; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # Build the payload with the real jq, then run the script with jq absent from
  # PATH: the stdin transport cannot extract the payload and must fail open.
  payload=$(jq -cn --arg c "cd $PRIMARY" '{tool_input:{command:$c}}')
  out=$(printf '%s' "$payload" | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "crew-checkout: fails open on the stdin path when jq is missing"
}

# --- end-to-end reach-over regression ---------------------------------------

test_e2e_reachover_regression() {
  # Reproduce the hole: from the crew worktree, WITHOUT the guard, a stray
  # `cd primary && git commit` lands a commit on the primary checkout's branch.
  local before after out rc
  before=$(git -C "$PRIMARY" rev-parse HEAD)
  (
    cd "$WORKTREE" || fail "cannot enter crew worktree"
    cd "$PRIMARY" || fail "cannot enter primary"
    git commit -q --allow-empty -m "reach-over from crew" || fail "commit failed"
  )
  after=$(git -C "$PRIMARY" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "baseline: reach-over did not land a commit on the primary; hole not reproduced"

  # With the guard, the exact command is denied before it can run.
  out=$("$CHECK" --claude --command "cd $PRIMARY && git commit -am x" 2>&1); rc=$?
  expect_code 2 "$rc" "guard must deny the exact reach-over command that caused the accident"
  assert_contains "$out" '[crew-cross-checkout-write]' "reach-over deny must carry the reason code"
  pass "crew-checkout: reproduces the primary-checkout reach-over and denies the exact command"
}

# --- shellcheck -------------------------------------------------------------

test_script_is_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck -x "$ROOT/bin/fm-crew-checkout-pretool-check.sh" >/dev/null 2>&1 \
    || fail "bin/fm-crew-checkout-pretool-check.sh is not shellcheck-clean"
  pass "bin/fm-crew-checkout-pretool-check.sh is shellcheck-clean"
}

test_decision_matrix
test_readonly_tool_file_allowed
test_pi_integration_form
test_inert_in_primary
test_inert_in_secondmate_home
test_inert_when_not_firstmate_repo
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_jq_on_stdin
test_e2e_reachover_regression
test_script_is_shellcheck_clean
