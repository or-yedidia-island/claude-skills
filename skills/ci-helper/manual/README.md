# CI Jobs Manual

Each job/task has its own file documenting quirks, flakiness, and troubleshooting.

## Naming Convention

`{repo}-{job-name}.md`

Examples:
- `cloud-build-docker.md`
- `apps-e2e-tests.md`
- `enterprise-ai-lint-backend.md`
- `cloud-helm-configurations-helm-validate.md`

## File Template

Each job file should follow this structure:

```markdown
# {Job Name}

## Overview
- **Repo**: cloud | apps | cloud-helm-configurations | enterprise-ai
- **CI System**: GitHub Actions | Jenkins | Nx
- **Trigger**: When this job runs
- **Purpose**: What it does
- **Duration**: Typical runtime

## Flakiness

### Frequency
How often it fails without code issues (e.g., 5%, 1 in 20 runs)

### Patterns
- Pattern 1: Description of failure mode
- Pattern 2: Another common flake

### Known Issues
List of documented flaky behaviors

## Failure Validation

### Is it Actually Failing?

Checks to determine if failure is real or flaky:

1. **Check A**: What to look for
   - Command: `command to run`
   - Expected: What you should see
   - If true: It's a real failure / It's flaky

2. **Check B**: Another validation
   - Look at logs for X
   - If Y appears, it's flaky

## Troubleshooting

### Common Failure 1: Name
- **Symptoms**: What you see in logs/UI
- **Root Cause**: Why it happens
- **Fix**: How to resolve
- **Rerun?**: Yes/No and why

### Common Failure 2: Name
- **Symptoms**: 
- **Root Cause**: 
- **Fix**: 
- **Rerun?**: 

## Quirks

Unusual behaviors or requirements:
- Quirk 1
- Quirk 2

## Commands

### View Logs
```bash
# GitHub Actions
gh run view {run-id} --log --job={job-id}

# Jenkins
curl "$JENKINS_URL/job/{job}/{build}/consoleText" --user "$JENKINS_USER:$JENKINS_TOKEN"
```

### Rerun
```bash
# GitHub Actions
gh run rerun {run-id} --failed

# Jenkins
curl -X POST "$JENKINS_URL/job/{job}/{build}/rebuild" --user "$JENKINS_USER:$JENKINS_TOKEN"
```

### Run Locally
```bash
# Commands to reproduce locally
```

## History
- YYYY-MM-DD: Note about significant change/fix
- YYYY-MM-DD: Flakiness increased after X change
```

## Quick Start

When you encounter a new job that needs documentation:

1. Create `{repo}-{job-name}.md` using the template above
2. Fill in as much as you know
3. Update as you learn more about the job's behavior
4. Keep the failure validation section accurate - it's the most important part!

## Example Jobs Documented

- **apps-ci-router.md** - Complete example showing:
  - Git permission flaky patterns
  - GitHub status update workflow (critical for router jobs)
  - Full agentic loop from diagnosis to PR status update
  
## Key Learnings

### Router Jobs & GitHub Status

Jenkins "router" jobs (like `apps-ci-router`) require special handling:

1. Manual rebuilds create a **new build number**
2. The PR status still points to the **old failed build**
3. You must **update GitHub commit status** via API to repoint the router

**Without updating the status, the PR shows ❌ even when rebuild passes ✅**

See `apps-ci-router.md` for the complete workflow.
