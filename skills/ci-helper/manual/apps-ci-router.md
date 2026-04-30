# Apps CI Router

## Overview
- **Repo**: apps
- **CI System**: Jenkins
- **Trigger**: Pull requests to apps repo
- **Purpose**: Routes PR builds to actual CI jobs, acts as the GitHub status check
- **Duration**: ~2-25 minutes (varies by affected projects)

## Flakiness

### Frequency
~10-15% failure rate due to infrastructure issues (git workspace corruption, file permissions)

### Patterns
- **Git checkout failures**: Permission denied when unlinking files
- **Workspace corruption**: Stale file locks from previous builds
- **NX dependency issues**: Missing modules breaking project graph

### Known Flaky Errors
- `error: unable to unlink old '...': Permission denied`
- `Warning: you are leaving N commits behind, not connected to any of your branches`
- `Could not checkout <commit-sha>`

## Failure Validation

### Is it Actually Failing?

Run these checks to determine if the failure is real or flaky:

#### 1. Check for Git Permission Errors
```bash
get_jenkins_console "apps-ci-router" <build-number> | grep -i "permission denied"
```
- **If found**: It's flaky infrastructure issue
- **Action**: Safe to rerun

#### 2. Check for Workspace Corruption
```bash
get_jenkins_console "apps-ci-router" <build-number> | grep -i "unable to unlink\|unable to create"
```
- **If found multiple times**: Workspace corruption (flaky)
- **Action**: Rebuild will use clean workspace

#### 3. Check for NX Project Graph Errors
```bash
get_jenkins_console "apps-ci-router" <build-number> | grep "Failed to process project graph"
```
- **If found with "Cannot find module"**: Real issue - missing dependency
- **If found with network errors**: Infrastructure (flaky)

#### 4. Compare with Recent Runs
```bash
# Check if same commit passed before
gh pr view <pr-number> --json commits
```
- **If same commit passed in earlier builds**: Definitely flaky
- **If always failing**: Real issue

## Troubleshooting

### Common Failure 1: Git Checkout Permission Denied
- **Symptoms**: 
  ```
  error: unable to unlink old 'path/to/file': Permission denied
  Could not checkout <sha>
  ```
- **Root Cause**: Jenkins workspace has locked files from crashed previous build
- **Fix**: Rebuild the job - Jenkins will allocate new workspace or clean existing
- **Rerun?**: Yes, always safe - 95% success rate on rerun

### Common Failure 2: Workspace File Locks
- **Symptoms**:
  ```
  warning: unable to unlink 'file': Permission denied
  error: unable to create file 'file': Permission denied
  ```
- **Root Cause**: File system locks on Jenkins agent from interrupted builds
- **Fix**: Rebuild triggers workspace cleanup
- **Rerun?**: Yes, infrastructure issue

### Common Failure 3: NX Module Not Found
- **Symptoms**:
  ```
  Failed to process project graph.
  Cannot find module '@some/package'
  ```
- **Root Cause**: PR introduced dependency that's not installed in Jenkins
- **Fix**: Add missing dependency to package.json or ensure it's properly declared
- **Rerun?**: No - this is a real code issue that needs fixing

### Common Failure 4: Build Timeout
- **Symptoms**: Build runs for 30+ minutes and times out
- **Root Cause**: NX affected includes too many projects, or tests are hanging
- **Fix**: Check what's affected, may need to split work or fix hanging tests
- **Rerun?**: Only if suspected infrastructure slowness

## Quirks

- **Router pattern**: This job acts as a "router" - the build URL shown on the PR is the router build, not the actual downstream build
- **Status updates**: Manual rebuilds don't automatically update PR status - must use GitHub API
- **Workspace reuse**: Jenkins reuses workspaces, leading to file lock issues
- **NX caching**: Uses Nx cloud cache, which can mask or surface issues
- **Multiple repos**: Checks out both `apps` and `dagger-modules` repos

## Commands

### View Logs
```bash
# Full console output
get_jenkins_console "apps-ci-router" <build-number>

# Check for specific error
get_jenkins_console "apps-ci-router" <build-number> | grep -A5 "error:"

# Check last 100 lines
get_jenkins_console "apps-ci-router" <build-number> | tail -100
```

### Rerun
```bash
# Get current build number from PR
gh pr view <pr-number> --json statusCheckRollup --jq '.statusCheckRollup[] | select(.context == "Affected Apps CI") | .targetUrl'

# Rebuild (creates new build number)
rebuild_jenkins_job "apps-ci-router" <build-number>

# Get new build number
new_build=$(get_last_build_number "apps-ci-router")

# Wait for completion
wait_for_jenkins_build "apps-ci-router" "$new_build" 600
```

### Update PR Status (CRITICAL)

**After manual rebuild, you MUST update the GitHub status** or the PR will still show the old failed build:

```bash
# Get PR commit SHA
commit_sha=$(gh pr view <pr-number> --json headRefOid --jq '.headRefOid')

# Update GitHub status to point to successful build
update_github_status_for_jenkins \
  "zeroabstraction/apps" \
  "$commit_sha" \
  "Affected Apps CI" \
  "https://jenkins.island.io/job/apps-ci-router/$new_build/" \
  "success" \
  "Build passed after rerun"
```

Without this step, the PR will show ❌ even though the rebuild passed ✅.

### Complete Agentic Loop
```bash
# Full workflow for fixing flaky build
old_build="128183"  # Failed build number from PR
pr_number="28709"

# 1. Rebuild
rebuild_jenkins_job "apps-ci-router" "$old_build"

# 2. Get new build
new_build=$(get_last_build_number "apps-ci-router")
echo "New build: $new_build"

# 3. Wait for completion (10 min timeout)
wait_for_jenkins_build "apps-ci-router" "$new_build" 600

# 4. Update PR status if successful
if [ $? -eq 0 ]; then
  commit_sha=$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid')
  update_github_status_for_jenkins \
    "zeroabstraction/apps" \
    "$commit_sha" \
    "Affected Apps CI" \
    "https://jenkins.island.io/job/apps-ci-router/$new_build/" \
    "success" \
    "Build passed after rerun"
  
  echo "✅ PR status updated - check now shows green!"
else
  echo "❌ Build still failing - not a flaky issue"
fi
```

## Run Locally

To reproduce the CI build locally:

```bash
# Navigate to apps repo
cd ~/work/apps

# Check what's affected (same as CI does)
nx show projects --affected --base=origin/main

# Run affected tests
nx affected --target=test --base=origin/main

# Run affected builds
nx affected --target=build --base=origin/main

# Run affected lint
nx affected --target=lint --base=origin/main
```

### IMPORTANT: CI runs `test:standalone`, not `test`

CI runs `yarn nx run <project>:test:standalone` which adds `--ci=true --coverage=true`.
This enforces coverage thresholds (often 100% lines). If you only run `nx test <project>`
locally you will NOT catch coverage failures.

**Always verify with:**
```bash
yarn nx run <project>:test:standalone
```

If it fails on coverage, you need tests for any new/uncovered files — not a flaky issue.

## History
- 2026-04-19: Documented git permission error pattern (10-15% flake rate)
- 2026-04-19: Added GitHub status update workflow for manual rebuilds
- 2026-04-19: Build #128183 failed with git permission errors, #128244 passed on rerun
