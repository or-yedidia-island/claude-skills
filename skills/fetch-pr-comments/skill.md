---
description: Fetch unresolved PR comments and review threads from GitHub. Use when the user wants to see unresolved comments, check what reviewers asked for, or get PR feedback to address.
---

You are a helper that fetches unresolved PR review comments and formats them for analysis.

# What This Does

Fetches all unresolved review threads from a GitHub PR using GraphQL and outputs them as a structured markdown file. This makes it easy to see what reviewers are asking for and address their feedback.

# Usage

Run the script from the repo root:

```bash
.claude/skills/fetch-pr-comments/fetch-comments.sh [PR_NUMBER] [OUTPUT_FILE]
```

# Parameters

1. **PR_NUMBER** (optional) - The PR number to fetch comments for. If omitted, auto-detects from the current branch.
2. **OUTPUT_FILE** (optional) - Path to write the markdown output. Defaults to `pr-unresolved-comments.md`.

# Examples

```bash
# Auto-detect PR from current branch, write to default file
.claude/skills/fetch-pr-comments/fetch-comments.sh

# Specific PR number
.claude/skills/fetch-pr-comments/fetch-comments.sh 12345

# Specific PR and output file
.claude/skills/fetch-pr-comments/fetch-comments.sh 12345 my-comments.md
```

# Requirements

- `gh` CLI must be authenticated
- `jq` must be installed
- Must be in a git repo with a GitHub remote

# Output Format

The script generates a markdown file containing:
- PR metadata (number, title, branch, URL)
- Total count of unresolved threads
- Each unresolved thread with:
  - File path and line number
  - Whether it's outdated (code has changed since comment)
  - Original comment with author
  - All replies in the thread

# Workflow

When the user wants to address PR comments:

1. Run the fetch script to get unresolved comments
2. Read the generated markdown file
3. Analyze what reviewers are asking for
4. Address each comment by making the requested changes
5. Optionally re-run to verify comments are resolved

# Important Notes

- If no unresolved comments exist, the script exits early with a success message
- Outdated threads (where code has changed) are marked — these may already be addressed
- The script fetches up to 100 review threads and 20 comments per thread
- Exit code 0 means success (even if no unresolved comments found)
