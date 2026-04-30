# {Job Name}

## Overview
- **Repo**: cloud | apps | cloud-helm-configurations | enterprise-ai
- **CI System**: GitHub Actions | Jenkins | Nx
- **Trigger**: push to main | pull_request | manual | scheduled
- **Purpose**: Brief description of what this job does
- **Duration**: ~5min (typical runtime)

## Flakiness

### Frequency
X% failure rate without code issues (e.g., 5%, 1 in 20 runs)

### Patterns
- **Pattern 1**: Timeout on external API calls
- **Pattern 2**: Intermittent test failures in module X

### Known Flaky Tests
- `test/path/to/flaky-test.spec.ts` - fails ~10% of time, timing issue
- `test/another-flaky.spec.ts` - network dependent

## Failure Validation

### Is it Actually Failing?

Run these checks to determine if the failure is real or flaky:

#### 1. Check for Known Error Messages
```bash
# View the logs
gh run view {run-id} --log | grep "KNOWN_FLAKY_ERROR"
```
- **Expected**: Should not see "KNOWN_FLAKY_ERROR"
- **If found**: It's flaky, safe to rerun

#### 2. Check Test Exit Code
```bash
# Look for exit code in logs
gh run view {run-id} --log | grep "exit code"
```
- **Exit code 137**: Out of memory - flaky infrastructure issue
- **Exit code 1**: Actual test failure - investigate

#### 3. Compare with Recent Runs
```bash
# Check if same commit passed before
gh run list --branch={branch} --limit 5
```
- **If passed before**: Likely flaky
- **If always failing**: Real issue

#### 4. Check for Infrastructure Issues
Look for:
- "unable to pull image" → Docker rate limit (flaky)
- "connection timeout" → Network issue (flaky)
- "assertion failed" → Real test failure (not flaky)

## Troubleshooting

### Common Failure 1: Docker Rate Limit
- **Symptoms**: "rate limit exceeded" when pulling images
- **Root Cause**: Anonymous Docker Hub pulls are rate limited
- **Fix**: Wait 10 minutes or use authenticated registry
- **Rerun?**: Yes, always safe to rerun

### Common Failure 2: Test Timeout
- **Symptoms**: "Test suite failed to run" with 30s timeout
- **Root Cause**: Slow test environment startup
- **Fix**: Increase timeout or optimize test setup
- **Rerun?**: Yes, usually passes on second attempt

### Common Failure 3: Dependency Installation Failure
- **Symptoms**: "npm install failed" or "yarn install failed"
- **Root Cause**: Registry connectivity or cache corruption
- **Fix**: Clear cache and retry
- **Rerun?**: Yes after cache clear

## Quirks

- Requires GITHUB_TOKEN with specific permissions
- Must run after "build" job completes
- Uses cached dependencies from previous run
- Sensitive to timezone (runs tests with UTC)

## Commands

### View Logs
```bash
# GitHub Actions - full run logs
gh run view {run-id} --log

# GitHub Actions - specific job logs
gh run view {run-id} --log --job={job-id}

# Jenkins
curl "$JENKINS_URL/job/{job-name}/{build-number}/consoleText" \
  --user "$JENKINS_USER:$JENKINS_TOKEN"
```

### Rerun
```bash
# GitHub Actions - rerun failed jobs only
gh run rerun {run-id} --failed

# GitHub Actions - rerun entire workflow
gh run rerun {run-id}

# Jenkins
curl -X POST "$JENKINS_URL/job/{job-name}/{build-number}/rebuild" \
  --user "$JENKINS_USER:$JENKINS_TOKEN"
```

### Run Locally
```bash
# Navigate to repo
cd /path/to/repo

# Run the same command CI runs
npm test -- --specific-suite

# Or with Nx
nx test {project-name}
```

### Debug Specific Test
```bash
# Run single test with verbose output
npm test -- path/to/test.spec.ts --verbose

# With Nx
nx test {project} --testFile=path/to/test.spec.ts
```

## History
- 2026-04-19: Created documentation
- (Add entries as patterns emerge)
