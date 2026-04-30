#!/bin/bash
# Jarvis API helper functions for test flakiness detection

JARVIS_API_BASE="https://jarvis.staging.island.io/api"

# Get all test collections from Jarvis (with control chars stripped)
_fetch_jarvis() {
  curl -s "$JARVIS_API_BASE/test-collections/get-all-test-collections" 2>/dev/null | tr -d '\000-\037' | tr -d '\177'
}

# Get flaky test statistics
get_flaky_stats() {
  echo "📊 Jarvis Flaky Test Statistics"
  echo "================================"
  echo ""

  _fetch_jarvis | jq -r '
    .testCollections[] |
    select(.name | contains("Flaky")) |
    "\(.name): \(.tests | length) tests"
  '

  echo ""
  local total=$(_fetch_jarvis | jq '[.testCollections[] | select(.name | contains("Flaky")) | .tests | length] | add')
  echo "Total flaky tests tracked: $total"
}

# Check if a test is in any flaky collection
# Usage: is_test_flaky <test-name> [class-name]
is_test_flaky() {
  local test_name=$1
  local class_name=${2:-""}

  local result
  if [ -n "$class_name" ]; then
    result=$(_fetch_jarvis | jq --arg test "$test_name" --arg class "$class_name" '
      .testCollections[] |
      select(.name | contains("Flaky")) |
      . as $coll |
      .tests[] |
      select(.name == $test and .className == $class) |
      {collection: $coll.name, className: .className}
    ' | head -1)
  else
    result=$(_fetch_jarvis | jq --arg test "$test_name" '
      .testCollections[] |
      select(.name | contains("Flaky")) |
      . as $coll |
      .tests[] |
      select(.name == $test) |
      {collection: $coll.name, className: .className}
    ' | head -1)
  fi

  if [ -n "$result" ] && [ "$result" != "" ]; then
    echo "✅ Test is in flaky collection"
    echo "$result" | jq -r '"   Collection: \(.collection)\n   Class: \(.className)"'
    return 0
  else
    echo "❌ Test not found in flaky collections"
    return 1
  fi
}

# Search for tests by name pattern
search_flaky_tests() {
  local pattern=$1

  if [ -z "$pattern" ]; then
    echo "Usage: search_flaky_tests <pattern>"
    return 1
  fi

  echo "🔍 Searching for flaky tests matching: $pattern"
  echo ""

  _fetch_jarvis | jq -r --arg pattern "$pattern" '
    .testCollections[] |
    select(.name | contains("Flaky")) as $coll |
    .tests[] |
    select(.name | test($pattern; "i")) |
    "  • \(.name)\n    Class: \(.className)\n    Collection: \($coll.name)\n"
  ' | head -50

  local count=$(_fetch_jarvis | jq --arg pattern "$pattern" '
    [.testCollections[] |
    select(.name | contains("Flaky")) |
    .tests[] |
    select(.name | test($pattern; "i"))] | length
  ')

  echo ""
  echo "Found $count matching test(s)"
}

# Get tests from specific collection
get_collection_tests() {
  local collection_name=$1

  if [ -z "$collection_name" ]; then
    echo "Usage: get_collection_tests <collection-name>"
    echo "Available collections: Flaky, AutoFlaky, AutoFlakyV2, ForbiddenAutoFlaky"
    return 1
  fi

  echo "📋 Tests in collection: $collection_name"
  echo "========================================"
  echo ""

  _fetch_jarvis | jq -r --arg name "$collection_name" '
    .testCollections[] |
    select(.name == $name) |
    .tests[] |
    "  • \(.name)\n    Class: \(.className)\n    Platform: \(.platform)\n"
  ' | head -100
}

# Quick check: is this a flaky test name?
quick_flaky_check() {
  local test_name=$1

  if [ -z "$test_name" ]; then
    echo "Usage: quick_flaky_check <test-name>"
    return 1
  fi

  is_test_flaky "$test_name"
}
