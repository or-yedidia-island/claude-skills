#!/bin/bash
# Nx helper functions

# Show affected projects for PR
show_affected_projects() {
  local base=${1:-origin/main}
  nx show projects --affected --base="$base"
}

# Run affected tests
run_affected_tests() {
  local base=${1:-origin/main}
  nx affected --target=test --base="$base" --verbose
}

# Run specific project tests
run_project_tests() {
  local project=$1
  nx test "$project" --verbose
}

# Run affected with specific target
run_affected_target() {
  local target=$1
  local base=${2:-origin/main}
  nx affected --target="$target" --base="$base"
}

# Clear Nx cache
clear_nx_cache() {
  echo "Clearing Nx cache..."
  nx reset
  echo "Cache cleared. Rerun your tests."
}

# Show dependency graph for affected
show_affected_graph() {
  local base=${1:-origin/main}
  nx graph --affected --base="$base"
}

# Check for circular dependencies
check_circular_deps() {
  echo "Checking for circular dependencies..."
  nx graph --file=graph.json 2>&1 | grep -i "circular" || echo "No circular dependencies found"
}

# Run affected with parallel execution
run_affected_parallel() {
  local target=$1
  local base=${2:-origin/main}
  local parallel=${3:-3}

  nx affected --target="$target" --base="$base" --parallel="$parallel"
}

# Get affected projects as JSON
get_affected_json() {
  local base=${1:-origin/main}
  nx show projects --affected --base="$base" --json
}
