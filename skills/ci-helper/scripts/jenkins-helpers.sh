#!/bin/bash
# Jenkins helper functions using curl

# Ensure required env vars are set
check_jenkins_auth() {
  if [ -z "$JENKINS_USER" ] || [ -z "$JENKINS_TOKEN" ] || [ -z "$JENKINS_URL" ]; then
    echo "Error: Set JENKINS_USER, JENKINS_TOKEN, and JENKINS_URL environment variables"
    return 1
  fi
  return 0
}

# Get build status
get_jenkins_build_status() {
  local job_name=$1
  local build_number=$2

  check_jenkins_auth || return 1

  curl -s "$JENKINS_URL/job/$job_name/$build_number/api/json" \
    --user "$JENKINS_USER:$JENKINS_TOKEN" \
    | jq -r '.result // "IN_PROGRESS"'
}

# Get build console output
get_jenkins_console() {
  local job_name=$1
  local build_number=$2

  check_jenkins_auth || return 1

  curl -s "$JENKINS_URL/job/$job_name/$build_number/consoleText" \
    --user "$JENKINS_USER:$JENKINS_TOKEN"
}

# Trigger a build
trigger_jenkins_build() {
  local job_name=$1
  shift
  local params="$@"

  check_jenkins_auth || return 1

  if [ -z "$params" ]; then
    curl -X POST "$JENKINS_URL/job/$job_name/build" \
      --user "$JENKINS_USER:$JENKINS_TOKEN"
  else
    curl -X POST "$JENKINS_URL/job/$job_name/buildWithParameters" \
      --user "$JENKINS_USER:$JENKINS_TOKEN" \
      --data-urlencode "$params"
  fi
}

# Rerun/rebuild existing build
rebuild_jenkins_job() {
  local job_name=$1
  local build_number=$2

  check_jenkins_auth || return 1

  curl -X POST "$JENKINS_URL/job/$job_name/$build_number/rebuild" \
    --user "$JENKINS_USER:$JENKINS_TOKEN"

  echo "Triggered rebuild of $job_name #$build_number"
}

# Get last build number
get_last_build_number() {
  local job_name=$1

  check_jenkins_auth || return 1

  curl -s "$JENKINS_URL/job/$job_name/api/json" \
    --user "$JENKINS_USER:$JENKINS_TOKEN" \
    | jq -r '.lastBuild.number'
}

# Wait for build to complete
# Usage: wait_for_jenkins_build <job-name> <build-number> [timeout_seconds]
# Returns: 0 if success, 1 if failure, 2 if timeout
wait_for_jenkins_build() {
  local job_name=$1
  local build_number=$2
  local timeout=${3:-1800}  # 30 minutes default

  check_jenkins_auth || return 1

  echo "⏳ Waiting for Jenkins build $job_name #$build_number (timeout: ${timeout}s)..."

  local elapsed=0
  local interval=10

  while [ $elapsed -lt $timeout ]; do
    # Fetch only the fields we need — the full response can contain control chars
    # in console output that break jq when passed through a shell variable.
    local building=$(curl -s "$JENKINS_URL/job/$job_name/$build_number/api/json?tree=building" \
      --user "$JENKINS_USER:$JENKINS_TOKEN" 2>/dev/null | jq -r '.building // false')
    local result=$(curl -s "$JENKINS_URL/job/$job_name/$build_number/api/json?tree=result" \
      --user "$JENKINS_USER:$JENKINS_TOKEN" 2>/dev/null | jq -r '.result // null')

    # Check if completed
    if [ "$building" = "false" ]; then
      if [ "$result" = "SUCCESS" ]; then
        echo "✅ Build completed successfully: $job_name #$build_number"
        local duration=$(curl -s "$JENKINS_URL/job/$job_name/$build_number/api/json?tree=duration" \
          --user "$JENKINS_USER:$JENKINS_TOKEN" 2>/dev/null | jq -r '.duration // 0')
        if [ "$duration" != "0" ] && [ "$duration" != "null" ]; then
          local duration_sec=$((duration / 1000))
          local duration_min=$((duration_sec / 60))
          echo "   Duration: ${duration_min}m $((duration_sec % 60))s"
        fi
        return 0
      elif [ "$result" = "FAILURE" ]; then
        echo "❌ Build failed: $job_name #$build_number"
        echo "   URL: $JENKINS_URL/job/$job_name/$build_number/"
        return 1
      elif [ "$result" = "ABORTED" ]; then
        echo "🚫 Build was aborted: $job_name #$build_number"
        return 1
      elif [ "$result" = "UNSTABLE" ]; then
        echo "⚠️  Build is unstable: $job_name #$build_number"
        return 1
      elif [ "$result" != "null" ]; then
        echo "⚠️  Build completed with result: $result"
        return 1
      fi
    fi

    # Still running
    echo "⏳ Still running... (${elapsed}s elapsed)"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "⏱️  Timeout reached (${timeout}s) - build still in progress"
  return 2
}

# Wait for specific Jenkins check on a PR to complete (by polling PR status)
# Usage: wait_for_jenkins_pr_check <pr-number> <check-name> [repo] [timeout_seconds]
# Returns: 0 if success, 1 if failure, 2 if timeout
wait_for_jenkins_pr_check() {
  local pr_number=$1
  local check_name=$2
  local repo=$3
  local timeout=${4:-1800}  # 30 minutes default

  echo "⏳ Waiting for Jenkins check '$check_name' on PR #$pr_number (timeout: ${timeout}s)..."

  local elapsed=0
  local interval=15  # Poll less frequently for Jenkins

  while [ $elapsed -lt $timeout ]; do
    # Get PR checks via GitHub
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

    # Find the Jenkins check
    local check=$(echo "$checks" | jq -r --arg name "$check_name" '
      .statusCheckRollup[] |
      select(.context == $name or .name == $name) |
      {
        name: (.name // .context),
        state: (.state // .conclusion),
        url: (.targetUrl // .detailsUrl)
      }
    ')

    if [ -z "$check" ] || [ "$check" = "null" ]; then
      echo "⚠️  Check '$check_name' not found on PR (may not have started yet)"
      sleep $interval
      elapsed=$((elapsed + interval))
      continue
    fi

    local state=$(echo "$check" | jq -r '.state')
    local url=$(echo "$check" | jq -r '.url')

    # Check completion status
    if [ "$state" = "SUCCESS" ] || [ "$state" = "success" ]; then
      echo "✅ Jenkins check passed: $check_name"
      echo "   URL: $url"
      return 0
    elif [ "$state" = "FAILURE" ] || [ "$state" = "failure" ]; then
      echo "❌ Jenkins check failed: $check_name"
      echo "   URL: $url"
      return 1
    elif [ "$state" = "ERROR" ] || [ "$state" = "error" ]; then
      echo "❌ Jenkins check errored: $check_name"
      echo "   URL: $url"
      return 1
    fi

    # Still pending/running
    echo "⏳ Jenkins check still running... (${elapsed}s elapsed) - State: $state"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "⏱️  Timeout reached (${timeout}s) - check still in progress"
  return 2
}

# Get Allure report for a failed automation build
# Usage: get_allure_report <job-name> <build-number>
# Shows: summary stats, failed test names, and failure messages
get_allure_report() {
  local job_name=$1
  local build_number=$2

  check_jenkins_auth || return 1

  local base_url="$JENKINS_URL/job/$job_name/$build_number/allure"

  echo "📊 Fetching Allure report for $job_name #$build_number..."
  echo ""

  # Get summary
  local summary=$(curl -s "$base_url/widgets/summary.json" --user "$JENKINS_USER:$JENKINS_TOKEN" 2>/dev/null)
  if [ $? -ne 0 ] || [ -z "$summary" ] || echo "$summary" | grep -q "404\|Not Found"; then
    echo "❌ No Allure report found for this build"
    return 1
  fi

  local failed=$(echo "$summary" | jq -r '.statistic.failed // 0')
  local passed=$(echo "$summary" | jq -r '.statistic.passed // 0')
  local skipped=$(echo "$summary" | jq -r '.statistic.skipped // 0')
  local total=$(echo "$summary" | jq -r '.statistic.total // 0')

  echo "Summary: $failed failed, $passed passed, $skipped skipped ($total total)"
  echo ""

  if [ "$failed" = "0" ]; then
    echo "✅ No failures"
    return 0
  fi

  # Get failed test details from suites, then fetch each test case for error details
  python3 -c "
import json, sys, urllib.request, base64, os

base_url = sys.argv[1]
user = os.environ.get('JENKINS_USER', '')
token = os.environ.get('JENKINS_TOKEN', '')
auth = base64.b64encode(f'{user}:{token}'.encode()).decode()

def fetch_json(url):
    req = urllib.request.Request(url)
    req.add_header('Authorization', f'Basic {auth}')
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except:
        return None

suites = fetch_json(f'{base_url}/data/suites.json')
if not suites:
    print('  Failed to fetch suites data')
    sys.exit(1)

def find_failed(node, path=''):
    name = node.get('name', '')
    current_path = f'{path}/{name}' if path else name
    if 'children' in node:
        for child in node['children']:
            yield from find_failed(child, current_path)
    else:
        if node.get('status') == 'failed':
            uid = node.get('uid', '')
            duration = node.get('time', {}).get('duration', 0)
            yield (uid, current_path, duration)

failed = []
for child in suites.get('children', []):
    failed.extend(find_failed(child))

print(f'❌ Failed tests ({len(failed)}):')
print()
for uid, name, duration in failed:
    print(f'  - {name} ({duration}ms)')
    if uid:
        detail = fetch_json(f'{base_url}/data/test-cases/{uid}.json')
        if detail:
            msg = detail.get('statusMessage', '')
            if msg:
                lines = msg.split('\n')[:20]
                print()
                print('    Error:')
                for line in lines:
                    print(f'    {line}')
                print()
" "$base_url" 2>/dev/null
}

# Update GitHub commit status to point to a different Jenkins build
# Usage: update_github_status_for_jenkins <owner/repo> <commit-sha> <context-name> <build-url> <state> [description]
# Example: update_github_status_for_jenkins "zeroabstraction/apps" "abc123" "Affected Apps CI" "https://jenkins.island.io/job/apps-ci-router/128244/" "success" "Build passed after rerun"
update_github_status_for_jenkins() {
  local repo=$1
  local commit_sha=$2
  local context=$3
  local build_url=$4
  local state=$5
  local description=${6:-"Updated by CI helper"}

  echo "📝 Updating GitHub status for $context..."
  echo "   Commit: $commit_sha"
  echo "   State: $state"
  echo "   URL: $build_url"

  gh api -X POST "repos/$repo/statuses/$commit_sha" \
    -f state="$state" \
    -f target_url="$build_url" \
    -f description="$description" \
    -f context="$context"

  if [ $? -eq 0 ]; then
    echo "✅ GitHub status updated successfully"
    return 0
  else
    echo "❌ Failed to update GitHub status"
    return 1
  fi
}
