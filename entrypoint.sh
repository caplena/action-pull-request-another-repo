#!/bin/sh
set -e
set -x

if [ -z "${INPUT_SOURCE_FOLDER:-}" ]; then
  echo "source_folder must be defined"
  exit 1
fi

if [ -z "${INPUT_PR_TITLE:-}" ]; then
  echo "pr_title must be defined"
  exit 1
fi

if [ -z "${INPUT_COMMIT_MSG:-}" ]; then
  echo "commit_msg must be defined"
  exit 1
fi

if [ "${INPUT_DESTINATION_HEAD_BRANCH:-}" = "main" ] || [ "${INPUT_DESTINATION_HEAD_BRANCH:-}" = "master" ]; then
  echo "Destination head branch cannot be 'main' nor 'master'"
  exit 1
fi

# Make sure gh CLI is authenticated when only API_TOKEN_GITHUB is provided.
if [ -z "${GH_TOKEN:-}" ] && [ -n "${API_TOKEN_GITHUB:-}" ]; then
  export GH_TOKEN="${API_TOKEN_GITHUB}"
fi
if [ -z "${GH_TOKEN:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="${GITHUB_TOKEN}"
fi
if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
  export GITHUB_TOKEN="${GH_TOKEN}"
fi

CLONE_TOKEN="${API_TOKEN_GITHUB:-}"
if [ -z "$CLONE_TOKEN" ]; then
  CLONE_TOKEN="${GH_TOKEN:-}"
fi
if [ -z "$CLONE_TOKEN" ]; then
  CLONE_TOKEN="${GITHUB_TOKEN:-}"
fi
if [ -z "$CLONE_TOKEN" ]; then
  echo "A GitHub token is required (API_TOKEN_GITHUB or GH_TOKEN/GITHUB_TOKEN)."
  exit 1
fi

HOME_DIR=$PWD
CLONE_DIR=$(mktemp -d)

echo "Setting git variables"
git config --global user.email "$INPUT_USER_EMAIL"
git config --global user.name "$INPUT_USER_NAME"

echo "Cloning destination git repository"
git clone "https://$CLONE_TOKEN@github.com/$INPUT_DESTINATION_REPO.git" "$CLONE_DIR"

echo "Creating folder"
mkdir -p "$CLONE_DIR/$INPUT_DESTINATION_FOLDER/"
cd "$CLONE_DIR"

echo "Checking if branch already exists"
git fetch --all

if git ls-remote --exit-code --heads origin "$INPUT_DESTINATION_HEAD_BRANCH" >/dev/null 2>&1; then
  BRANCH_EXISTS=1
  git checkout -B "$INPUT_DESTINATION_HEAD_BRANCH" "origin/$INPUT_DESTINATION_HEAD_BRANCH"
else
  BRANCH_EXISTS=0
  git checkout -B "$INPUT_DESTINATION_BASE_BRANCH" "origin/$INPUT_DESTINATION_BASE_BRANCH"
  git checkout -b "$INPUT_DESTINATION_HEAD_BRANCH"
fi

echo "Copying files"
rsync -a --delete "$HOME_DIR/$INPUT_SOURCE_FOLDER" "$CLONE_DIR/$INPUT_DESTINATION_FOLDER/"
git add .

if ! git diff --cached --quiet; then
  git commit --message "$INPUT_COMMIT_MSG"

  echo "Pushing git commit"
  git push -u origin HEAD:"$INPUT_DESTINATION_HEAD_BRANCH"

  SHORT_SHA=$(printf "%.7s" "$GITHUB_SHA")
  PUSHED_BY="${GITHUB_ACTOR:-unknown-user}"
  SOURCE_REPOSITORY_NAME="${GITHUB_REPOSITORY#*/}"
  BODY_HEADER="$SOURCE_REPOSITORY_NAME - schema changes"
  BODY_ENTRY="$SHORT_SHA: source PR not found - $PUSHED_BY"

  # Best effort: prefix with source PR title for this commit.
  SOURCE_PR_DATA=$(gh api \
    -H "Accept: application/vnd.github+json" \
    "/repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/pulls" 2>/dev/null || true)
  SOURCE_PR_TITLE=$(printf "%s" "$SOURCE_PR_DATA" | jq -r '.[0].title // empty' 2>/dev/null || true)
  if [ -n "$SOURCE_PR_TITLE" ]; then
    BODY_ENTRY="$SHORT_SHA: $SOURCE_PR_TITLE - $PUSHED_BY"
  fi

  PR_NUMBER=$(gh pr list \
    --repo "$INPUT_DESTINATION_REPO" \
    --head "$INPUT_DESTINATION_HEAD_BRANCH" \
    --base "$INPUT_DESTINATION_BASE_BRANCH" \
    --state open \
    --json number \
    --jq '.[0].number // empty')

  if [ -n "$PR_NUMBER" ]; then
    echo "Updating pull request body"
    CURRENT_BODY=$(gh pr view "$PR_NUMBER" --repo "$INPUT_DESTINATION_REPO" --json body --jq '.body // ""')
    if [ -n "$CURRENT_BODY" ]; then
      case "$CURRENT_BODY" in
        *"$BODY_HEADER"*)
          BODY_WITH_HEADER="$CURRENT_BODY"
          ;;
        *)
          BODY_WITH_HEADER=$(printf "%s\n\n%s" "$BODY_HEADER" "$CURRENT_BODY")
          ;;
      esac
      UPDATED_BODY=$(printf "%s\n%s" "$BODY_WITH_HEADER" "$BODY_ENTRY")
    else
      UPDATED_BODY=$(printf "%s\n\n%s" "$BODY_HEADER" "$BODY_ENTRY")
    fi
    gh pr edit "$PR_NUMBER" --repo "$INPUT_DESTINATION_REPO" -b "$UPDATED_BODY"
  else
    echo "Creating a pull request"
    NEW_PR_BODY=$(printf "%s\n\n%s" "$BODY_HEADER" "$BODY_ENTRY")
    if [ -n "${INPUT_PULL_REQUEST_REVIEWERS:-}" ]; then
      gh pr create \
        --repo "$INPUT_DESTINATION_REPO" \
        -t "$INPUT_PR_TITLE" \
        -b "$NEW_PR_BODY" \
        -B "$INPUT_DESTINATION_BASE_BRANCH" \
        -H "$INPUT_DESTINATION_HEAD_BRANCH" \
        -r "$INPUT_PULL_REQUEST_REVIEWERS"
    else
      gh pr create \
        --repo "$INPUT_DESTINATION_REPO" \
        -t "$INPUT_PR_TITLE" \
        -b "$NEW_PR_BODY" \
        -B "$INPUT_DESTINATION_BASE_BRANCH" \
        -H "$INPUT_DESTINATION_HEAD_BRANCH"
    fi
  fi
else
  echo "No changes detected"
fi
