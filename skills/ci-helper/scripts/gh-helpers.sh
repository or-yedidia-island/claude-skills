#!/bin/bash
# GitHub CLI helper functions for CI operations

# Get PR status with detailed check information
get_pr_status() {
  local pr_number=$1
  local repo=$2

  if [ -n "$repo" ]; then
    gh pr view "$pr_number" --repo "$repo" --json statusCheckRollup,state,url
  else
    gh pr view "$pr_number" --json statusCheckRollup,state,url
  fi
}

# Rerun failed jobs for a PR
rerun_failed_pr_jobs() {
  local pr_number=$1
  local repo=$2

  echo "Fetching failed runs for PR #$pr_number..."

  if [ -n "$repo" ]; then
    local runs=$(gh pr view "$pr_number" --repo "$repo" --json statusCheckRollup --jq '.statusCheckRollup[] | select(.conclusion == "FAILURE") | .workflowRun.databaseId' | sort -u)
  else
    local runs=$(gh pr view "$pr_number" --json statusCheckRollup --jq '.statusCheckRollup[] | select(.conclusion == "FAILURE") | .workflowRun.databaseId' | sort -u)
  fi

  if [ -z "$runs" ]; then
    echo "No failed runs found."
    return 0
  fi

  echo "Found failed runs: $runs"
  for run_id in $runs; do
    echo "Rerunning run $run_id..."
    if [ -n "$repo" ]; then
      gh run rerun "$run_id" --repo "$repo" --failed
    else
      gh run rerun "$run_id" --failed
    fi
  done
}

# Watch PR until all checks complete (hybrid: watch runs + poll for status checks)
watch_pr() {
  local pr_number=$1
  local repo=$2
  local timeout=${3:-3600}  # 1 hour default for polling phase

  echo "Watching PR #$pr_number..."

  # Fetch required status checks from branch protection
  local base_branch
  if [ -n "$repo" ]; then
    base_branch=$(gh pr view "$pr_number" --repo "$repo" --json baseRefName --jq '.baseRefName' 2>/dev/null)
  else
    base_branch=$(gh pr view "$pr_number" --json baseRefName --jq '.baseRefName' 2>/dev/null)
  fi

  local required_checks=""
  if [ -n "$base_branch" ]; then
    echo "📋 Fetching required checks for branch '$base_branch'..."
    if [ -n "$repo" ]; then
      required_checks=$(gh api "repos/$repo/branches/$base_branch/protection/required_status_checks" --jq '.contexts[]' 2>&1 | grep -v "^{" || true)
    else
      # Get repo from current directory
      local current_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
      if [ -n "$current_repo" ]; then
        required_checks=$(gh api "repos/$current_repo/branches/$base_branch/protection/required_status_checks" --jq '.contexts[]' 2>&1 | grep -v "^{" || true)
      fi
    fi

    if [ -n "$required_checks" ]; then
      local check_count=$(echo "$required_checks" | wc -l | tr -d ' ')
      echo "✓ Found $check_count required check(s)"
    else
      echo "ℹ️  No branch protection or required checks found - will treat all failures as blocking"
    fi
  fi

  # Phase 1: Watch all GitHub Actions runs
  if [ -n "$repo" ]; then
    local run_ids=$(gh pr view "$pr_number" --repo "$repo" --json statusCheckRollup --jq '.statusCheckRollup[].workflowRun.databaseId' | grep -v '^$' | sort -u)
  else
    local run_ids=$(gh pr view "$pr_number" --json statusCheckRollup --jq '.statusCheckRollup[].workflowRun.databaseId' | grep -v '^$' | sort -u)
  fi

  if [ -n "$run_ids" ]; then
    echo "📊 Found $(echo "$run_ids" | wc -l | tr -d ' ') GitHub Actions runs to watch"
    for run_id in $run_ids; do
      if [ -n "$repo" ]; then
        gh run watch "$run_id" --repo "$repo" --exit-status || true
      else
        gh run watch "$run_id" --exit-status || true
      fi
    done
  fi

  # Phase 2: Poll for any remaining checks (Jenkins, status checks, etc)
  echo ""
  echo "🔄 Polling for non-workflow checks (Jenkins, status checks)..."

  local interval=30
  local elapsed=0
  local last_status=""
  local tmpfile=$(mktemp)
  trap "rm -f $tmpfile" EXIT

  while [ $elapsed -lt $timeout ]; do
    # Get all checks and save to temp file
    if [ -n "$repo" ]; then
      gh pr view "$pr_number" --repo "$repo" --json statusCheckRollup > "$tmpfile" 2>/dev/null
    else
      gh pr view "$pr_number" --json statusCheckRollup > "$tmpfile" 2>/dev/null
    fi

    if [ $? -ne 0 ]; then
      echo "❌ Failed to fetch PR status"
      rm -f "$tmpfile"
      return 1
    fi

    # Count checks by status using temp file
    # Handle both GitHub Actions checks (status field) and Jenkins/status checks (state/conclusion field)
    local total=$(jq '[.statusCheckRollup[] | select((.name // .context) != null)] | length' < "$tmpfile" 2>/dev/null)
    local completed=$(jq '[.statusCheckRollup[] | select((.name // .context) != null and ((.status == "COMPLETED" and .conclusion != "PENDING") or .state == "SUCCESS" or .state == "FAILURE"))] | length' < "$tmpfile" 2>/dev/null)
    local failed=$(jq '[.statusCheckRollup[] | select((.name // .context) != null and ((.status == "COMPLETED" and .conclusion == "FAILURE") or .state == "FAILURE"))] | length' < "$tmpfile" 2>/dev/null)
    local pending=$(jq '[.statusCheckRollup[] | select((.name // .context) != null and ((.status == "IN_PROGRESS") or (.status == "PENDING") or (.status == "QUEUED") or (.status == "COMPLETED" and .conclusion == "PENDING") or .state == "PENDING"))] | length' < "$tmpfile" 2>/dev/null)

    # Check if jq commands succeeded
    if [ -z "$total" ] || [ -z "$completed" ] || [ -z "$failed" ] || [ -z "$pending" ]; then
      echo "⚠️  Warning: Failed to parse PR status, retrying..."
      sleep $interval
      elapsed=$((elapsed + interval))
      continue
    fi

    # Check if any failed checks are required
    if [ "$failed" -gt 0 ]; then
      echo ""
      echo "⚠️  Found $failed failed check(s), checking if required..."

      # Get failed check names and URLs (handle both GitHub Actions and Jenkins/status checks)
      local failed_checks=$(jq -r '.statusCheckRollup[] | select((.name // .context) != null and ((.status == "COMPLETED" and .conclusion == "FAILURE") or .state == "FAILURE")) | "\((.name // .context))|\((.detailsUrl // .targetUrl // "no URL"))"' < "$tmpfile")

      local has_required_failure=false
      local required_failed_checks=""
      local optional_failed_checks=""

      while IFS='|' read -r name url; do
        # Check if this check name is in the required_checks list
        local is_required=false
        if [ -z "$required_checks" ]; then
          # No branch protection found - treat all failures as required
          is_required=true
        elif echo "$required_checks" | grep -qF "$name"; then
          is_required=true
        fi

        if [ "$is_required" = true ]; then
          has_required_failure=true
          required_failed_checks="${required_failed_checks}  - $name: $url\n"
        else
          optional_failed_checks="${optional_failed_checks}  - $name (optional): $url\n"
        fi
      done <<< "$failed_checks"

      # Show all failed checks
      if [ -n "$required_failed_checks" ]; then
        echo ""
        echo "❌ Required check(s) failed - stopping watch"
        echo ""
        echo "Failed required checks:"
        echo -e "$required_failed_checks"
      fi

      if [ -n "$optional_failed_checks" ]; then
        echo ""
        echo "ℹ️  Optional check(s) failed (not blocking):"
        echo -e "$optional_failed_checks"
      fi

      if [ "$pending" -gt 0 ]; then
        echo ""
        echo "⚠️  Note: $pending check(s) still pending/running"
      fi

      # Only exit with error if there's a required failure
      if [ "$has_required_failure" = true ]; then
        rm -f "$tmpfile"
        return 1
      else
        echo ""
        echo "✅ All required checks passed, continuing to watch..."
      fi
    fi

    # Build status summary
    local current_status="$completed/$total complete"
    if [ "$pending" -gt 0 ]; then
      current_status="$current_status ($pending pending)"
    fi

    # Print status if changed
    if [ "$current_status" != "$last_status" ]; then
      echo "⏳ $current_status (${elapsed}s elapsed)"
      last_status="$current_status"
    fi

    # Check if all checks are complete and passed
    if [ "$completed" -eq "$total" ] && [ "$total" -gt 0 ]; then
      echo ""
      echo "✅ All checks passed!"
      rm -f "$tmpfile"
      return 0
    fi

    # Wait before next poll
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "⏱️  Timeout reached (${timeout}s) - checks still in progress"
  rm -f "$tmpfile"
  return 2
}

# List recent workflow runs
list_recent_runs() {
  local workflow=$1
  local limit=${2:-10}
  local repo=$3

  if [ -n "$workflow" ]; then
    if [ -n "$repo" ]; then
      gh run list --workflow="$workflow" --limit="$limit" --repo "$repo" --json databaseId,conclusion,name,headBranch,createdAt
    else
      gh run list --workflow="$workflow" --limit="$limit" --json databaseId,conclusion,name,headBranch,createdAt
    fi
  else
    if [ -n "$repo" ]; then
      gh run list --limit="$limit" --repo "$repo" --json databaseId,conclusion,name,headBranch,createdAt
    else
      gh run list --limit="$limit" --json databaseId,conclusion,name,headBranch,createdAt
    fi
  fi
}

# Wait for specific GitHub Actions run to complete
# Usage: wait_for_gh_run <run-id> [repo] [timeout_seconds]
# Returns: 0 if success, 1 if failure, 2 if timeout
wait_for_gh_run() {
  local run_id=$1
  local repo=$2
  local timeout=${3:-1800}  # 30 minutes default

  echo "⏳ Waiting for run #$run_id to complete (timeout: ${timeout}s)..."

  local elapsed=0
  local interval=10

  while [ $elapsed -lt $timeout ]; do
    # Get run status
    local run_info
    if [ -n "$repo" ]; then
      run_info=$(gh run view "$run_id" --repo "$repo" --json status,conclusion,name 2>/dev/null)
    else
      run_info=$(gh run view "$run_id" --json status,conclusion,name 2>/dev/null)
    fi

    if [ $? -ne 0 ]; then
      echo "❌ Failed to fetch run status"
      return 1
    fi

    local status=$(echo "$run_info" | jq -r '.status')
    local conclusion=$(echo "$run_info" | jq -r '.conclusion')
    local name=$(echo "$run_info" | jq -r '.name')

    # Check if completed
    if [ "$status" = "completed" ]; then
      if [ "$conclusion" = "success" ]; then
        echo "✅ Run completed successfully: $name"
        return 0
      elif [ "$conclusion" = "failure" ]; then
        echo "❌ Run failed: $name"
        return 1
      elif [ "$conclusion" = "cancelled" ]; then
        echo "🚫 Run was cancelled: $name"
        return 1
      else
        echo "⚠️  Run completed with conclusion: $conclusion"
        return 1
      fi
    fi

    # Still running
    echo "⏳ Still running... (${elapsed}s elapsed) - Status: $status"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "⏱️  Timeout reached (${timeout}s) - run still in progress"
  return 2
}

# Wait for specific check on a PR to complete
# Usage: wait_for_pr_check <pr-number> <check-name> [repo] [timeout_seconds]
# Returns: 0 if success, 1 if failure, 2 if timeout
wait_for_pr_check() {
  local pr_number=$1
  local check_name=$2
  local repo=$3
  local timeout=${4:-1800}  # 30 minutes default

  echo "⏳ Waiting for check '$check_name' on PR #$pr_number (timeout: ${timeout}s)..."

  local elapsed=0
  local interval=10

  while [ $elapsed -lt $timeout ]; do
    # Get PR checks
    local checks
    if [ -n "$repo" ]; then
      checks=$(gh pr view "$pr_number" --repo "$repo" --json statusCheckRollup 2>/dev/null)
    else
      checks=$(gh pr view "$pr_number" --json statusCheckRollup 2>/dev/null)
    fi

    if [ $? -ne 0 ]; then
      echo "❌ Failed to fetch PR checks"
      return 1
    fi

    # Find the specific check
    local check=$(echo "$checks" | jq -r --arg name "$check_name" '
      .statusCheckRollup[] |
      select((.name // .context) == $name) |
      {
        name: (.name // .context),
        status: (.status // "completed"),
        conclusion: (.conclusion // .state),
        url: (.detailsUrl // .targetUrl)
      }
    ')

    if [ -z "$check" ] || [ "$check" = "null" ]; then
      echo "⚠️  Check '$check_name' not found on PR (may not have started yet)"
      sleep $interval
      elapsed=$((elapsed + interval))
      continue
    fi

    local check_status=$(echo "$check" | jq -r '.status')
    local conclusion=$(echo "$check" | jq -r '.conclusion')

    # GitHub Actions checks
    if [ "$check_status" = "COMPLETED" ] || [ "$check_status" = "completed" ]; then
      if [ "$conclusion" = "SUCCESS" ] || [ "$conclusion" = "success" ]; then
        echo "✅ Check passed: $check_name"
        return 0
      elif [ "$conclusion" = "FAILURE" ] || [ "$conclusion" = "failure" ]; then
        echo "❌ Check failed: $check_name"
        local url=$(echo "$check" | jq -r '.url')
        echo "   URL: $url"
        return 1
      else
        echo "⚠️  Check completed with status: $conclusion"
        return 1
      fi
    fi

    # Still running
    echo "⏳ Check still running... (${elapsed}s elapsed) - Status: $check_status"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "⏱️  Timeout reached (${timeout}s) - check still in progress"
  return 2
}
