# Cypress E2E (apps)

## Overview
- **Repo**: apps
- **CI System**: GitHub Actions (via Nx Cloud agents) + Cypress Cloud
- **Trigger**: Pull requests (as part of `Nx Affected - E2E, Lint, Test`)
- **Purpose**: Runs Cypress component/e2e tests for affected projects
- **Duration**: Varies by project (10s - 5min per spec)

## New Cypress E2E Project Checklist

When adding a new Cypress e2e project, CI will fail if these are missing:

1. **`projectId`** in `cypress.config.ts` — must be a real Cypress Cloud project ID (6-char alphanumeric), not `'placeholder'`. Create one at https://cloud.cypress.io.
2. **`CYPRESS_RECORD_KEY`** in the project's env config — without this, CI can't authenticate with Cypress Cloud and the test fails immediately (~3-6s).

### Symptoms of Missing Config
- **Missing/wrong `projectId`**: `cypress: default-group` check fails, Cypress Cloud link returns 404 or wrong project
- **Missing `CYPRESS_RECORD_KEY`**: e2e task fails in 3-6s in CI (Cache Miss) but passes locally. This is because local runs don't record to Cypress Cloud, but CI does.

### How to Fix
- Get a `projectId` from Cypress Cloud (create project if needed)
- Add `CYPRESS_RECORD_KEY` to the e2e project's environment configuration
- Look at other e2e projects (e.g. `apps/browser/desktop/pages/ai-chat-connection-lost-e2e/cypress.config.ts`) for reference

## Failure Validation

### Is it Actually Failing?

#### 1. Check Duration
- **Fails in 3-6s with Cache Miss**: Almost certainly a config/auth issue (missing `CYPRESS_RECORD_KEY`, wrong `projectId`), NOT a real test failure
- **Fails in 10s+**: Likely a real test failure or flaky test — investigate the actual error

#### 2. Run Locally
```bash
yarn nx e2e <project-name>
```
If it passes locally but fails in CI in <6s, it's a CI config issue, not a code issue.

#### 3. Check Cypress Cloud
The `cypress: default-group` status check links to the Cypress Cloud run. Check if:
- The project exists in Cypress Cloud
- The run was recorded (if not, `CYPRESS_RECORD_KEY` is missing/wrong)
- The tests actually executed (if 0 tests ran, it's a setup issue)

## Troubleshooting

### Common Failure 1: Missing CYPRESS_RECORD_KEY
- **Symptoms**: e2e task fails in 3-6s, passes locally
- **Root Cause**: CI needs `CYPRESS_RECORD_KEY` to record to Cypress Cloud
- **Fix**: Add the key to the project's env config
- **Rerun?**: No — needs config fix

### Common Failure 2: Placeholder projectId
- **Symptoms**: `cypress: default-group` fails, Cypress Cloud link is wrong
- **Root Cause**: `projectId: 'placeholder'` in `cypress.config.ts`
- **Fix**: Create a real project in Cypress Cloud and update the config
- **Rerun?**: No — needs code fix

### Common Failure 3: Flaky Cypress Test
- **Symptoms**: Fails intermittently with actual test errors, `cypress/flake` check reports it
- **Root Cause**: Timing issues, network dependencies
- **Fix**: Rerun or fix the flaky test
- **Rerun?**: Yes, if `cypress/flake` flags it as flaky

### Common Failure 4: `cypress/flake` Transient Early Failure
- **Symptoms**: `cypress/flake` reports FAILURE early in the CI run (within first ~10min), while other checks are still pending. Clears to SUCCESS on its own without any rerun.
- **Root Cause**: Cypress Cloud reporting timing — the flake detection check appears to report a stale or intermediate result before the full run completes.
- **Fix**: No action needed — wait. It self-resolves consistently.
- **Rerun?**: No — just keep watching. Observed on 3 consecutive pushes to PR #28709 (2026-04-23), all self-resolved.

## Commands

### Run Locally
```bash
yarn nx e2e <project-e2e-name>
```

### Check Other Projects for Reference
```bash
grep -r "projectId" apps/browser/desktop/pages/*/cypress.config.ts
```

## History
- 2026-04-21: Created after `quick-actions-dialog-e2e` consistently failed in CI (3-6s) due to missing `CYPRESS_RECORD_KEY` and placeholder `projectId`
- 2026-04-23: `cypress/flake` check failed transiently on PR #28709 after rebase, then cleared on next poll. Confirms the `cypress/flake` check can report failures that self-resolve — may be a timing issue with Cypress Cloud reporting.
