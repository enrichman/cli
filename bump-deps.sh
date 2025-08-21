#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration & Defaults ---
RANCHER_MODULE_PATH="github.com/rancher/rancher"
RANCHER_UPSTREAM_REMOTE="upstream"
CLI_UPSTREAM_REMOTE="upstream" # Upstream for the CLI repo
DRY_RUN=false
SKIP_GH=false
IGNORE_VULNS=false
VERSION=""
STASHED=false

# --- Argument Parsing ---
# A robust loop to handle flags in any order.
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            echo "DRY RUN MODE: No changes will be committed or pushed."
            shift # past argument
            ;;
        --skip-gh)
            SKIP_GH=true
            echo "Skipping all 'gh' CLI interactions."
            shift # past argument
            ;;
        --ignore-vulns)
            IGNORE_VULNS=true
            echo "Ignoring Trivy vulnerability scan results."
            shift # past argument
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            # Assume the first non-flag argument is the version.
            if [ -z "$VERSION" ]; then
                VERSION="$1"
            else
                echo "Error: Multiple versions specified. Only one is allowed."
                exit 1
            fi
            shift # past argument
            ;;
    esac
done

# --- Pre-flight Checks ---
if [ -z "$VERSION" ]; then
  echo "Usage: $0 [--dry-run] [--skip-gh] [--ignore-vulns] <version>"
  echo "Example: $0 v2.12"
  exit 1
fi

# Check for trivy
if ! command -v trivy &> /dev/null; then
  echo "❌  Error: 'trivy' is not installed. Please install it to continue."
  exit 1
fi

# Automatically skip gh interactions if the CLI is not available or not authenticated.
if [ "$SKIP_GH" = false ]; then
  if ! command -v gh &> /dev/null || ! gh auth status &> /dev/null; then
    echo "⚠️  Warning: 'gh' CLI not found or user not authenticated."
    echo "    Automatically skipping PR creation. Please create the PR manually."
    SKIP_GH=true
  fi
fi

# --- Variable Setup ---
RANCHER_REPO_PATH="../rancher"
RANCHER_BRANCH="release/$VERSION"
CLI_BRANCH="$VERSION"

echo ""
echo "--- Starting Dependency Bump Check ---"
echo "Rancher Branch: $RANCHER_BRANCH"
echo "CLI Branch:     $CLI_BRANCH"
echo "--------------------------------------"
echo ""

# --- Stash any local changes to avoid errors ---
echo "🧹  Checking for and stashing any uncommitted changes..."
if ! git diff-index --quiet HEAD --; then
    git stash push -m "bump-deps-script-stash-$(date +%s)"
    STASHED=true
fi
echo ""


# --- Fetch Latest Data ---
echo "🔄  Fetching latest updates for rancher/rancher..."
pushd "$RANCHER_REPO_PATH" > /dev/null
git fetch --all
popd > /dev/null

echo "🔄  Fetching latest updates for rancher/cli..."
git fetch --all
echo ""

# --- Get Latest Rancher Tag ---
echo "🔎  Finding the latest tag on rancher branch '$RANCHER_BRANCH'..."
LATEST_RANCHER_TAG=$(git -C "$RANCHER_REPO_PATH" describe --tags --abbrev=0 "$RANCHER_UPSTREAM_REMOTE/$RANCHER_BRANCH")

if [ -z "$LATEST_RANCHER_TAG" ]; then
  echo "❌  No tags found on rancher branch '$RANCHER_BRANCH'. Exiting."
  if [ "$STASHED" = true ]; then git stash pop; fi
  exit 0
fi
echo "✅  Latest tag found on rancher: $LATEST_RANCHER_TAG"
echo ""

# --- Sync and Compare with CLI Branch ---
echo "🔄  Syncing local CLI branch '$CLI_BRANCH' with '$CLI_UPSTREAM_REMOTE'..."
# Create or reset the local branch to match the upstream branch exactly, avoiding ambiguity.
git checkout -B "$CLI_BRANCH" "$CLI_UPSTREAM_REMOTE/$CLI_BRANCH"
echo ""

echo "🔎  Checking if tag '$LATEST_RANCHER_TAG' is already on CLI branch '$CLI_BRANCH'..."
CURRENT_CLI_TAG=$(git describe --tags --abbrev=0 || true)

if [ "$LATEST_RANCHER_TAG" == "$CURRENT_CLI_TAG" ]; then
  echo "✅  Dependencies are already up to date with tag '$LATEST_RANCHER_TAG'. Nothing to do."
  if [ "$STASHED" = true ]; then
      echo " unstashing previous changes..."
      git stash pop
  fi
  exit 0
fi
echo "⬆️  New update required. Current CLI tag is '$CURRENT_CLI_TAG'."
echo ""

# --- Start the Update Process ---
echo "🚀  Starting update process for tag '$LATEST_RANCHER_TAG'..."

RANCHER_COMMIT_HASH=$(git -C "$RANCHER_REPO_PATH" rev-parse "refs/tags/$LATEST_RANCHER_TAG")
echo "  - Using rancher commit: $RANCHER_COMMIT_HASH"

BUMP_BRANCH="bump-deps-$LATEST_RANCHER_TAG"
echo "  - Target branch will be: $BUMP_BRANCH"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "DRY RUN: Skipping branch creation, commit, push, and PR creation."
  if [ "$STASHED" = true ]; then
      echo " unstashing previous changes..."
      git stash pop
  fi
  echo "--- Done ---"
  exit 0
fi

# --- The following actions are skipped during a dry run ---

# If the branch exists, reset it to the clean starting point. Otherwise, create it.
if git rev-parse --verify --quiet "$BUMP_BRANCH" > /dev/null; then
  echo "⚠️  Warning: Branch '$BUMP_BRANCH' already exists locally. Resetting it to a clean state."
  git checkout "$BUMP_BRANCH"
  git reset --hard "$CLI_BRANCH"
else
  echo "  - Creating new branch: $BUMP_BRANCH"
  git checkout -b "$BUMP_BRANCH" "$CLI_BRANCH"
fi

echo "  - Updating Go modules..."
for pkg in $(grep "$RANCHER_MODULE_PATH" go.mod | awk '{print $1}'); do
  echo "    - Updating $pkg"
  go get "$pkg@$RANCHER_COMMIT_HASH"
done

echo "  - Running 'go mod tidy'..."
go mod tidy
echo ""

# Check if there are any actual changes in the go.mod or go.sum files.
if [ -z "$(git status --porcelain go.mod go.sum)" ]; then
  echo "✅  No dependency changes were needed after running 'go get'. The workspace is clean."
  echo "   Switching back to the original branch '$CLI_BRANCH' and cleaning up."
  git checkout "$CLI_BRANCH"
  git branch -D "$BUMP_BRANCH"
  if [ "$STASHED" = true ]; then
      echo " unstashing previous changes..."
      git stash pop
  fi
  echo "--- Done ---"
  exit 0
fi

# --- Security Scan ---
echo "🛡️  Scanning for vulnerabilities with trivy..."
# Use --exit-code 1 to make trivy fail if vulnerabilities are found.
if ! trivy --scanners vuln fs --exit-code 1 . ; then
    if [ "$IGNORE_VULNS" = true ]; then
        echo "⚠️  Warning: Vulnerabilities were found, but proceeding due to --ignore-vulns flag."
    else
        echo "❌  Error: Vulnerabilities found. To proceed anyway, use the --ignore-vulns flag."
        # Clean up the failed attempt before popping the stash
        git reset --hard HEAD
        git checkout "$CLI_BRANCH"
        if [ "$STASHED" = true ]; then
            echo " unstashing previous changes..."
            git stash pop
        fi
        exit 1
    fi
else
    echo "✅  Trivy scan completed with no vulnerabilities found."
fi
echo ""

COMMIT_MESSAGE="chore: Bump rancher dependencies to $LATEST_RANCHER_TAG"
echo "  - Committing changes..."
git commit -am "$COMMIT_MESSAGE"

echo "  - Pushing branch '$BUMP_BRANCH' to origin..."
# Use --force-with-lease to safely overwrite the remote branch if it exists.
git push --force-with-lease -u origin "$BUMP_BRANCH"
echo ""

# Conditionally create or edit the PR
if [ "$SKIP_GH" = false ]; then
  PR_TITLE="[$VERSION] Bump \`rancher/rancher\` to \`$LATEST_RANCHER_TAG\`"
  
  # Get the ls-remote command and output for the PR body
  LS_REMOTE_COMMAND="git ls-remote $RANCHER_UPSTREAM_REMOTE $LATEST_RANCHER_TAG"
  LS_REMOTE_OUTPUT=$(git -C "$RANCHER_REPO_PATH" ls-remote $RANCHER_UPSTREAM_REMOTE $LATEST_RANCHER_TAG)
  
  PR_BODY=$(cat <<EOF
\`\`\`
$LS_REMOTE_COMMAND
$LS_REMOTE_OUTPUT
\`\`\`
EOF
)

  # Determine the upstream repository name (e.g., rancher/cli)
  UPSTREAM_URL=$(git remote get-url "$CLI_UPSTREAM_REMOTE")
  CLI_UPSTREAM_REPO=$(echo "$UPSTREAM_URL" | sed -E 's/.*github.com[:\/](.*)\.git/\1/')

  # Check if a PR already exists for this branch
  EXISTING_PR=$(gh pr list --repo "$CLI_UPSTREAM_REPO" --head "$BUMP_BRANCH" --json number --jq '.[0].number' || true)

  if [ -n "$EXISTING_PR" ]; then
    echo "  - Found existing PR #$EXISTING_PR. Updating title, body, and reviewers..."
    gh pr edit "$EXISTING_PR" --repo "$CLI_UPSTREAM_REPO" --title "$PR_TITLE" --body "$PR_BODY" --add-assignee "@me" --add-reviewer "rancher/collie"
    echo "🎉  Successfully updated existing Pull Request #$EXISTING_PR."
  else
    echo "  - Creating Pull Request against repository '$CLI_UPSTREAM_REPO'..."
    gh pr create --repo "$CLI_UPSTREAM_REPO" --title "$PR_TITLE" --body "$PR_BODY" --base "$CLI_BRANCH" --assignee "@me" --reviewer "rancher/collie" --fill
    echo "🎉  Successfully created a new Pull Request to update dependencies to $LATEST_RANCHER_TAG."
  fi
else
  echo "✅  Skipping PR creation as requested."
  echo "🎉  Branch '$BUMP_BRANCH' has been pushed. Please create a PR manually."
fi

# Pop the stash at the very end of a successful run
if [ "$STASHED" = true ]; then
    echo " unstashing previous changes..."
    # Ensure we are on the original branch before popping
    git checkout "$CLI_BRANCH"
    git stash pop
fi
echo "--- Done ---"
