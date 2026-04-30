#!/bin/bash

# Fetch unresolved PR comments and review threads
# Usage: fetch-comments.sh [PR_NUMBER] [OUTPUT_FILE]
# If PR_NUMBER is omitted, it will try to detect from current branch

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get PR number from argument or current branch
if [ -n "$1" ]; then
    PR_NUMBER="$1"
else
    echo -e "${YELLOW}No PR number provided, detecting from current branch...${NC}"
    PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null || echo "")
    if [ -z "$PR_NUMBER" ]; then
        echo -e "${RED}Error: Could not detect PR for current branch. Please provide PR number as argument.${NC}"
        echo "Usage: $0 [PR_NUMBER] [OUTPUT_FILE]"
        exit 1
    fi
    echo -e "${GREEN}Found PR #${PR_NUMBER}${NC}"
fi

# Get output file from argument or use default
OUTPUT_FILE="${2:-pr-unresolved-comments.md}"

# Get repo owner and name from git remote
REPO_FULL=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
REPO_OWNER=$(echo "$REPO_FULL" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO_FULL" | cut -d'/' -f2)

echo -e "${YELLOW}Fetching PR details...${NC}"

# Get PR info
PR_INFO=$(gh pr view "$PR_NUMBER" --json title,url,headRefName)
PR_TITLE=$(echo "$PR_INFO" | jq -r '.title')
PR_URL=$(echo "$PR_INFO" | jq -r '.url')
PR_BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName')

echo -e "${YELLOW}Fetching review threads via GraphQL...${NC}"

# Fetch all review threads
THREADS_JSON=$(gh api graphql -f query="
query {
  repository(owner: \"$REPO_OWNER\", name: \"$REPO_NAME\") {
    pullRequest(number: $PR_NUMBER) {
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          comments(first: 20) {
            nodes {
              author { login }
              body
              path
              line
              createdAt
            }
          }
        }
      }
    }
  }
}")

# Count unresolved threads
UNRESOLVED_COUNT=$(echo "$THREADS_JSON" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length')

echo -e "${YELLOW}Found ${UNRESOLVED_COUNT} unresolved review threads${NC}"

if [ "$UNRESOLVED_COUNT" -eq 0 ]; then
    echo -e "${GREEN}🎉 No unresolved comments! PR is ready.${NC}"
    exit 0
fi

# Generate markdown file
cat > "$OUTPUT_FILE" << EOF
# Unresolved PR Comments & Review Threads

**PR:** [#${PR_NUMBER} - ${PR_TITLE}](${PR_URL})
**Branch:** \`${PR_BRANCH}\`
**Date Generated:** $(date +%Y-%m-%d)
**Total Unresolved Review Threads:** ${UNRESOLVED_COUNT}

> **Note:** This file contains all unresolved review conversations/threads from the PR, including the original comment and all replies in each thread.

---

EOF

# Format and append threads
echo "$THREADS_JSON" | jq -r '
.data.repository.pullRequest.reviewThreads.nodes[] |
select(.isResolved == false) |
"## Thread " + (if .isOutdated then "(Outdated)" else "" end) + "\n\n**File:** `" + (.comments.nodes[0].path // "N/A") + "`  \n**Line:** " + ((.comments.nodes[0].line // "N/A") | tostring) + "  \n**Resolved:** ❌\n\n" +
(.comments.nodes | to_entries | map(
  if .key == 0 then
    "### Original Comment by @" + .value.author.login + "\n\n" + .value.body + "\n"
  else
    "#### Reply by @" + .value.author.login + "\n\n" + .value.body + "\n"
  end
) | join("\n")) +
"\n---\n\n"
' >> "$OUTPUT_FILE"

echo -e "${GREEN}✅ Successfully created ${OUTPUT_FILE}${NC}"
echo -e "${GREEN}   File size: $(ls -lh "$OUTPUT_FILE" | awk '{print $5}')${NC}"
echo -e "${GREEN}   Threads: ${UNRESOLVED_COUNT}${NC}"
