# Automation Distributor V2

## Overview
- **Repo**: apps (triggers automation repo tests against apps builds)
- **CI System**: Jenkins
- **Trigger**: PR push (via apps-ci-router)
- **Purpose**: Runs Windows/Mac endpoint automation tests (Canary, Stable, Desktop MV3) against the extension build from the PR
- **Duration**: ~55min typical
- **PR Check Names**: "Windows Canary", "Windows Stable", "Windows Desktop MV3 Automation", "Android Automation"

## Flakiness

### Frequency
High flakiness (~30-40% of runs have at least one flaky test failure)

### Patterns
- **Extension log assertion**: Tests fail in teardown because the extension logged an error during the test, even if the test logic itself passed
- **Timeout**: Tests fail with timeout waiting for UI elements to appear
- **Infrastructure**: Jarvis suite creation/closure failures

### Known Flaky Tests
- Various `management-integration` E2E tests (fail in 1s = infrastructure setup failure)
- Tests relying on extension toolbar icon rendering timing

## Failure Validation

### Is it Actually Failing?

#### 1. Check the Allure Report
```bash
get_allure_report "automation-distributor-v2" <build-number>
```
This shows the actual failed test names and error messages. The Jenkins console only shows a Jarvis suite ID.

#### 2. Analyze the Error Message
- **"No implementation for RPC"**: Real failure — an RPC method was called but not registered. Check if your PR removed or renamed an RPC handler.
- **"Teardown threw exception... Found errors in extension log"**: The test itself may have passed, but the extension logged an error. Check if the logged error is related to your changes.
- **"Timeout" / "Element not found"**: Often flaky due to slow test environment. Check if your PR changed UI layout/timing.

#### 3. Check if Test is Related to Your Changes
- If the failed test is in a module you didn't touch → likely flaky
- If the error message references code you changed (RPC methods, services) → real failure

#### 4. Check Jarvis Decision
In the Jenkins console, look for:
```
useJarvisSuiteDecision enabled: applying Jarvis decision (FAILURE)
```
Jarvis makes the pass/fail decision based on known flaky test filtering. If it says FAILURE, at least one non-flaky test failed.

## Troubleshooting

### Common Failure 1: RPC Not Implemented
- **Symptoms**: `"No implementation for RPC. module: X, method: Y"` in extension error log
- **Root Cause**: An RPC method is being called but has no registered handler (removed, renamed, or not loaded due to feature flag)
- **Fix**: Ensure the RPC handler is registered in the background service
- **Rerun?**: No — this is a real failure

### Common Failure 2: Extension Log Errors in Teardown
- **Symptoms**: `"TestCleanup method ... Teardown threw exception. AssertFailedException: Expected logEntries to be empty"` 
- **Root Cause**: The test's teardown asserts no errors were logged. Any error in the extension log (even unrelated) fails the test.
- **Fix**: Fix the underlying extension error, or if unrelated to your PR, it's flaky
- **Rerun?**: Depends — check if the logged error is from your changes

### Common Failure 3: Suite Failures in 1 Second
- **Symptoms**: Many tests "fail" in ~1s with Cache Miss
- **Root Cause**: Infrastructure/agent setup failure, tests never actually ran
- **Fix**: Rerun
- **Rerun?**: Yes, always safe

## Quirks

- The Jenkins console does NOT show individual test results — only a Jarvis suite ID
- Must use `get_allure_report` to see actual test failures and error messages
- Allure reports are stored as Jenkins artifacts and also in S3 (`s3://jenkins-allure-reports/automation-distributor-v2/<build>/`)
- S3 access requires specific IAM permissions (not available to all devs)
- The Allure report via Jenkins API (`/allure/data/...`) is always accessible with Jenkins credentials
- `retriesCount: 2` means the test was retried twice and still failed

## Commands

### View Allure Report (Failed Tests + Errors)
```bash
get_allure_report "automation-distributor-v2" <build-number>
```

### View Jenkins Console
```bash
get_jenkins_console "automation-distributor-v2" <build-number>
```

### Rebuild
```bash
rebuild_jenkins_job "automation-distributor-v2" <build-number>
```

### Get Build Status
```bash
get_jenkins_build_status "automation-distributor-v2" <build-number>
```

## History
- 2026-04-20: Created documentation after investigating Windows Desktop MV3 failure on PR #28709 (RPC error: aiQuickActions.getActiveTabAIQuickActions not implemented)
- 2026-04-21: Android Automation failed on PR #28709 (build #195141). Jarvis suite decision was FAILURE. Allure report not accessible via Jenkins API (parse error). Rerun (build #195594) passed. Confirmed flaky — UI-only changes should not affect Android automation.
