#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
MOCK_BIN="$TMP_DIR/bin"
HOME_DIR="$TMP_DIR/home"
WORK_DIR="$TMP_DIR/work"
REMOTE_SEED="$TMP_DIR/remote-seed"
REMOTE_BARE="$TMP_DIR/remote-bare.git"
PR_BODY_FILE="$TMP_DIR/pr-body.txt"
PR_TITLE_FILE="$TMP_DIR/pr-title.txt"
PR_NUMBER_FILE="$TMP_DIR/pr-number.txt"
PR_EXISTS_FILE="$TMP_DIR/pr-exists.txt"
LOG_FILE="$TMP_DIR/test.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN" "$HOME_DIR" "$WORK_DIR" "$REMOTE_SEED"
: > "$LOG_FILE"

REAL_GIT="$(command -v git)"
export TEST_REAL_GIT="$REAL_GIT"
export TEST_REMOTE_BARE_REPO="$REMOTE_BARE"
export TEST_PR_BODY_FILE="$PR_BODY_FILE"
export TEST_PR_TITLE_FILE="$PR_TITLE_FILE"
export TEST_PR_NUMBER_FILE="$PR_NUMBER_FILE"
export TEST_PR_EXISTS_FILE="$PR_EXISTS_FILE"

run_quiet() {
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    echo "FAIL: test.e2e.sh (see log below)" >&2
    tail -n 120 "$LOG_FILE" >&2
    exit 1
  fi
}

cat >"$MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
real_git="${TEST_REAL_GIT:?TEST_REAL_GIT is required}"

cmd="${1:-}"
shift || true

if [[ "$cmd" == "clone" ]]; then
  src="${1:-}"
  dst="${2:-}"
  if [[ "$src" =~ ^https://.*@github\.com/.+\.git$ ]]; then
    exec "$real_git" clone "${TEST_REMOTE_BARE_REPO:?TEST_REMOTE_BARE_REPO is required}" "$dst"
  fi
fi

exec "$real_git" "$cmd" "$@"
EOF

cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

pr_body_file="${TEST_PR_BODY_FILE:?TEST_PR_BODY_FILE is required}"
pr_title_file="${TEST_PR_TITLE_FILE:?TEST_PR_TITLE_FILE is required}"
pr_number_file="${TEST_PR_NUMBER_FILE:?TEST_PR_NUMBER_FILE is required}"
pr_exists_file="${TEST_PR_EXISTS_FILE:?TEST_PR_EXISTS_FILE is required}"

if [[ "${1:-}" == "api" ]]; then
  if [[ "${2:-}" == "PATCH" ]]; then
    body=""
    prev=""
    for arg in "$@"; do
      if [[ "$prev" == "-f" && "$arg" == body=* ]]; then
        body="${arg#body=}"
      fi
      prev="$arg"
    done
    printf '%s' "$body" > "$pr_body_file"
    exit 0
  fi

  endpoint="${@: -1}"
  case "$endpoint" in
    */commits/testing-chars/pulls)
      printf '%s\n' '[{"title":"feature(app-123): testing chars","html_url":"https://google.com"}]'
      ;;
    */commits/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/pulls)
      printf '%s\n' '[{"title":"fix(app-9460): Improve testing.","html_url":"https://google.com"}]'
      ;;
    *)
      printf '%s\n' '[]'
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  if [[ -f "$pr_exists_file" ]] && [[ "$(cat "$pr_exists_file")" == "1" ]]; then
    cat "$pr_number_file"
  fi
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  if [[ -f "$pr_body_file" ]]; then
    cat "$pr_body_file"
  fi
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
  body=""
  title=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "-b" ]]; then
      body="$arg"
    fi
    if [[ "$prev" == "-t" ]]; then
      title="$arg"
    fi
    prev="$arg"
  done
  printf '%s' "1" > "$pr_number_file"
  printf '%s' "1" > "$pr_exists_file"
  printf '%s' "$body" > "$pr_body_file"
  printf '%s' "$title" > "$pr_title_file"
  exit 0
fi

echo "Unexpected gh invocation: $*" >&2
exit 1
EOF

chmod +x "$MOCK_BIN/git" "$MOCK_BIN/gh"

export PATH="$MOCK_BIN:$PATH"
export HOME="$HOME_DIR"

# Prepare destination repository (base branch: dev).
run_quiet "$REAL_GIT" init -b dev "$REMOTE_SEED"
(
  cd "$REMOTE_SEED"
  run_quiet "$REAL_GIT" config user.email "seed@example.com"
  run_quiet "$REAL_GIT" config user.name "seed-bot"
  mkdir -p build
  printf '%s\n' '{"schema":"initial"}' > build/rest-api-ui.json
  run_quiet "$REAL_GIT" add .
  run_quiet "$REAL_GIT" commit -m "seed"
)
run_quiet "$REAL_GIT" clone --bare "$REMOTE_SEED" "$REMOTE_BARE"

run_action() {
  local sha="$1"
  local actor="$2"
  local source_contents="$3"

  mkdir -p "$WORK_DIR/tmp/internal"
  printf '%s\n' "$source_contents" > "$WORK_DIR/tmp/internal/rest-api-ui.json"

  (
    cd "$WORK_DIR"
    export INPUT_SOURCE_FOLDER="tmp/internal/rest-api-ui.json"
    export INPUT_DESTINATION_REPO="caplena/caplena-app-next"
    export INPUT_DESTINATION_FOLDER="build"
    export INPUT_DESTINATION_BASE_BRANCH="dev"
    export INPUT_DESTINATION_HEAD_BRANCH="ci/schema-update"
    export INPUT_USER_EMAIL="bot@example.com"
    export INPUT_USER_NAME="caplena-bot"
    export INPUT_PR_TITLE="chore: schema update"
    export INPUT_COMMIT_MSG="chore(api): schema update from API"
    export INPUT_PULL_REQUEST_REVIEWERS="elibolonur"
    export API_TOKEN_GITHUB="dummy-token"
    export GITHUB_REPOSITORY="caplena/helloworld"
    export GITHUB_SHA="$sha"
    export GITHUB_ACTOR="$actor"
    run_quiet bash "$ROOT_DIR/entrypoint.sh"
  )
}

echo "--- Setup done"
echo "--- Running case: create PR body from one schema change"
TEST_SHA="testing-chars"
SHORT_SHA="${TEST_SHA:0:7}"
run_action "$TEST_SHA" "username" '{"schema":"v1"}'

EXPECTED_HEADER="helloworld - schema changes"
EXPECTED_FIRST_ENTRY="[$SHORT_SHA](https://github.com/caplena/helloworld/commit/$TEST_SHA): [feature(app-123): testing chars](https://google.com) - username"

echo "--- Verifying PR body format"
for expected in "$EXPECTED_HEADER" "$EXPECTED_FIRST_ENTRY"; do
  if ! awk -v line="$expected" '$0 == line { found=1 } END { exit found ? 0 : 1 }' "$PR_BODY_FILE"; then
    echo "Missing expected line in PR body: $expected" >&2
    echo "Actual body:" >&2
    cat "$PR_BODY_FILE" >&2
    exit 1
  fi
done

# Verify destination branch content changed.
echo "--- Verifying destination repository update"
VERIFY_CLONE="$TMP_DIR/verify"
run_quiet "$REAL_GIT" clone "$REMOTE_BARE" "$VERIFY_CLONE"
(
  cd "$VERIFY_CLONE"
  run_quiet "$REAL_GIT" checkout ci/schema-update
  if ! awk '$0 == "{\"schema\":\"v1\"}" { found=1 } END { exit found ? 0 : 1 }' build/rest-api-ui.json; then
    echo "Destination repository file did not update to v1." >&2
    cat build/rest-api-ui.json >&2
    exit 1
  fi
)

echo "--- Example PR output"
echo "PR title: $(cat "$PR_TITLE_FILE")"
echo "PR body:"
cat "$PR_BODY_FILE"
echo

echo "--- PASS: e2e action simulation succeeded."
