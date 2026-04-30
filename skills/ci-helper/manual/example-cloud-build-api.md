# Build API (Example)

## Overview
- **Repo**: cloud
- **CI System**: GitHub Actions
- **Trigger**: pull_request, push to main
- **Purpose**: Build and test the API service Docker image
- **Duration**: ~8 minutes

## Flakiness

### Frequency
~8% failure rate (approximately 1 in 12 runs fail without code issues)

### Patterns
- **Docker rate limiting**: "rate limit exceeded" when pulling base images
- **Yarn install timeout**: Registry connection issues during dependency install
- **Test timeout**: Integration tests occasionally timeout waiting for database

### Known Flaky Tests
- `tests/api/integration/auth.spec.ts` - ~5% flake rate, timing dependent
- `tests/api/integration/webhooks.spec.ts` - ~3% flake rate, network dependent

## Failure Validation

### Is it Actually Failing?

Run these checks to determine if the failure is real or flaky:

#### 1. Check for Docker Rate Limit
```bash
gh run view {run-id} --log | grep "rate limit exceeded"
```
- **If found**: It's flaky infrastructure issue
- **Action**: Wait 10 mins and rerun

#### 2. Check for Network/Timeout Errors
```bash
gh run view {run-id} --log | grep -E "(ETIMEDOUT|ECONNREFUSED|timeout)"
```
- **If found in test output**: Likely flaky
- **If found in build step**: Could be real issue, check registry status

#### 3. Compare with Previous Runs
```bash
gh run list --branch=main --limit=5 --workflow="Build API" --json conclusion,headSha
```
- **If same commit passed before**: Definitely flaky
- **If always failing**: Real issue

#### 4. Check Specific Test Failures
Look for assertion failures vs infrastructure failures:
- **"AssertionError: expected X to equal Y"**: Real test failure
- **"Exceeded timeout of 30000 ms"**: Likely flaky
- **"ECONNREFUSED"**: Infrastructure/timing issue (flaky)

## Troubleshooting

### Common Failure 1: Docker Rate Limit
- **Symptoms**: `Error response from daemon: toomanyrequests: You have reached your pull rate limit`
- **Root Cause**: Anonymous Docker Hub pulls limited to 100/6hrs
- **Fix**: Wait or use authenticated pulls
- **Rerun?**: Yes, always safe - wait 10 minutes first

### Common Failure 2: Integration Test Timeout
- **Symptoms**: `Error: Timeout - Async callback was not invoked within the 30000 ms timeout`
- **Root Cause**: Database or external service slow to respond in CI environment
- **Fix**: The tests should have retry logic - this is a known CI environment issue
- **Rerun?**: Yes, usually passes on second attempt

### Common Failure 3: Yarn Install Failure
- **Symptoms**: `error An unexpected error occurred: "https://registry.yarnpkg.com/...: ETIMEDOUT"`
- **Root Cause**: NPM registry connectivity issues in CI runner
- **Fix**: Rerun - usually transient
- **Rerun?**: Yes, almost always passes on retry

### Common Failure 4: TypeScript Compilation Error
- **Symptoms**: `error TS2304: Cannot find name 'X'` or `error TS2345: Argument of type...`
- **Root Cause**: Actual code problem
- **Fix**: Fix the TypeScript errors in the code
- **Rerun?**: No, real code issue - needs fixing

## Quirks

- Requires `NPM_TOKEN` secret to be set for private package access
- Uses layer caching from previous builds - first run after cache clear is slower
- Integration tests require PostgreSQL service container
- Must run after "Lint" job completes successfully
- Runs on `ubuntu-latest` runners which occasionally have different Node versions

## Commands

### View Logs
```bash
# Full run logs
gh run view {run-id} --log

# Specific job logs
gh run view {run-id} --log --job="Build API"

# Filter for errors
gh run view {run-id} --log | grep -i "error"
```

### Rerun
```bash
# Rerun failed jobs only (recommended)
gh run rerun {run-id} --failed

# Rerun entire workflow
gh run rerun {run-id}

# Watch the rerun
gh run watch {run-id}
```

### Run Locally
```bash
# Navigate to cloud repo
cd ~/work/cloud

# Build Docker image
docker build -t api:local -f services/api/Dockerfile .

# Run tests
nx test api

# Run integration tests
nx test api --testPathPattern=integration
```

### Debug Specific Test
```bash
# Run single flaky test
nx test api --testFile=tests/api/integration/auth.spec.ts --verbose

# Run with increased timeout
nx test api --testTimeout=60000
```

## History
- 2026-04-19: Created documentation after observing 8% flake rate
- 2026-04-15: Docker rate limiting became more common
- 2026-04-10: Added retry logic to webhook tests (reduced flake from 8% to 3%)
