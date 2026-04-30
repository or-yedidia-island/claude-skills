# Nx Cloud (apps)

## Overview
- **Repo**: apps
- **CI System**: GitHub Actions + Nx Cloud (distributed execution)
- **Trigger**: Pull requests
- **Purpose**: Runs lint, stylelint, test, component-test, typecheck, build-storybook, e2e-ci across all affected projects via distributed Nx Cloud agents
- **Duration**: ~30min (2400+ tasks across 30 agents)
- **PR Check Names**: "Nx: lint stylelint test component-test typecheck build-storybook e2e-ci", "Nx Affected - E2E, Lint, Test"

## Flakiness

### Frequency
Moderate (~10-15% of runs fail due to flaky e2e tests or infrastructure issues)

### Patterns
- **management-integration e2e flakes**: Individual e2e spec files in `management-integration:e2e-ci` fail intermittently
- **Nx Cloud agent failures**: Occasionally agents disconnect or time out
- **Cache miss storms**: After main branch changes, all tasks are cache misses which increases infra pressure

### Known Flaky Tasks
- `management-integration:e2e-ci--src/e2e/modules-v2/data*` - e2e tests that fail intermittently

## Failure Validation

### Is it Actually Failing?

#### 1. Check the Summary Report
In the GH Actions logs, look for the Distributed Execution Summary Report:
- **1-2 failed out of 2400+**: Very likely flaky
- **Many failures in same project**: More likely real
- **All failures are e2e-ci tasks**: Likely flaky

#### 2. Check the Nx Cloud Run Link
The status check links to `https://island.gc.ent.nx.app/runs/<id>`. Open it to see which specific tasks failed.

#### 3. Check if Failure is in Your Affected Projects
- If the failed task is in a project you didn't change and isn't downstream of your changes → not your code
- Use `yarn nx show projects --affected` locally to see what your PR affects

#### 4. Look at Task Duration
- **Fails in <5s**: Infrastructure/setup issue, not a real test failure
- **Fails in 30s+**: Actual test execution happened, may be real

## Troubleshooting

### Common Failure 1: Single e2e Flake
- **Symptoms**: 1 of 2400+ tasks failed, it's an e2e-ci task
- **Root Cause**: Flaky e2e test (timing, network, test isolation)
- **Fix**: Rerun the GH Actions workflow
- **Rerun?**: Yes, safe to rerun

### Common Failure 2: Lint/Typecheck Failure
- **Symptoms**: lint or typecheck task fails
- **Root Cause**: Real code issue
- **Fix**: Fix the lint/type error locally
- **Rerun?**: No — needs code fix

### Common Failure 3: Nx Cloud AI Fix in Progress
- **Symptoms**: `[fix-ci] Failed to get AI fix: An AI fix is already in progress`
- **Root Cause**: Nx Cloud's auto-fix feature is already running for this pipeline
- **Fix**: Ignore this message, it's informational
- **Rerun?**: N/A

## Quirks

- The GH Actions job "Nx Affected - E2E, Lint, Test" orchestrates distributed execution; the actual tasks run on Nx Cloud agents
- The Nx Cloud status check ("Nx: lint stylelint test component-test typecheck build-storybook e2e-ci") is a separate GitHub status context
- Both checks reflect the same Nx Cloud run — if one fails, both fail
- Nx Cloud has an AI auto-fix feature that may trigger on failures
- Task logs are available at the Nx Cloud run URL, not in GH Actions logs

## Commands

### View GH Actions Logs
```bash
gh run view <run-id> --repo zeroabstraction/apps --log-failed
```

### Rerun Failed Jobs
```bash
gh run rerun <run-id> --repo zeroabstraction/apps --failed
```

### Check Affected Projects Locally
```bash
yarn nx show projects --affected
```

### Run Specific Task Locally
```bash
yarn nx run <project>:<target>
```

## History
- 2026-04-21: Created after Nx Cloud failed on PR #28709 (run BplY3rbRrT). Single e2e flake: `management-integration:e2e-ci--src/e2e/modules-v2/data*` (1/2448 tasks). Unrelated to PR changes.
- 2026-04-23: Second run (RTW1egretO) also failed with same pattern — single `management-integration:e2e-ci--src/e2e/modules-v2/data*` failure (1/2448 tasks). Confirmed recurring flake in this test area.
