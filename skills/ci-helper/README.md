# CI Helper Skill

A comprehensive CI debugging and automation skill for cloud, apps, cloud-helm-configurations, and enterprise-ai repositories.

## Features

✅ **CI Failure Investigation** - Analyze failed jobs and identify root causes  
✅ **Flaky Test Detection** - Track and automatically retry known flaky tests  
✅ **Auto-Rerun** - Intelligently rerun failed jobs that are likely to pass  
✅ **Knowledge Base** - Searchable manual of documented CI issues  
✅ **Multi-System Support** - GitHub Actions, Jenkins, Nx integration  
✅ **Script Library** - Reusable bash functions for common operations

## Usage

Invoke the skill with:
```
/ci-helper
```

Then provide the PR URL or number you want to investigate:
```
Check PR #1234 in cloud repo
```

Or investigate recent failures:
```
What's failing in the apps repo CI?
```

## Manual Structure

The `manual/` directory contains:

- **flaky-tests.md** - Known flaky tests across all repos
- **common-issues.md** - Recurring problems and solutions
- **jenkins-jobs.md** - Jenkins job documentation
- **github-actions.md** - GitHub Actions workflow docs
- **nx-tasks.md** - Nx monorepo CI patterns

## Scripts

Helper functions in `scripts/`:

- **gh-helpers.sh** - GitHub CLI operations (rerun, status, watch)
- **jenkins-helpers.sh** - Jenkins API operations (curl-based)
- **nx-helpers.sh** - Nx affected commands and cache management

## Setup

### Jenkins Authentication

Set environment variables for Jenkins access:
```bash
export JENKINS_USER="your-username"
export JENKINS_TOKEN="your-api-token"
export JENKINS_URL="https://jenkins.example.com"
```

Add to your `~/.zshrc` or `~/.bashrc` to persist.

### GitHub CLI

Ensure `gh` is authenticated:
```bash
gh auth login
```

### Nx

No special setup needed - just ensure `nx` is available in the repo.

## Workflow

1. **Identify repo** from PR URL or ask user
2. **Fetch CI status** using gh CLI or Jenkins API
3. **Check manual** for known issues
4. **Analyze failures** and determine if flaky
5. **Recommend action** (rerun, fix, investigate)
6. **Execute** (with permission) and track results
7. **Document** new findings in manual

## Examples

### Check PR status
```
/ci-helper
Check cloud PR #456
```

### Rerun failed jobs
```
/ci-helper
Rerun failed jobs on apps PR #789
```

### Investigate specific failure
```
/ci-helper
Why is the "Build Docker Image" job failing on enterprise-ai PR #123?
```

### Document new flaky test
```
The integration test keeps timing out - can you document this?
```

## Tips

- Always check the manual first before deep investigation
- Document patterns you notice - future you will thank present you
- Rerun cautiously - not everything is flaky
- Update Jenkins URL and credentials in manual after setup
- Keep flaky test frequency estimates current

## Contributing to Manual

When you discover new issues:

1. Add entry to appropriate manual file
2. Include repo, symptoms, cause, solution
3. Note frequency and last-seen date
4. Provide exact commands/workarounds
5. Keep it actionable and specific
