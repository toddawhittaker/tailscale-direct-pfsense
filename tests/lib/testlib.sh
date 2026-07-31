#!/bin/sh

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMPDIRS=""

test_ok() {
  printf 'ok - %s\n' "$*"
}

test_not_ok() {
  printf 'not ok - %s\n' "$*" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  desc="$1"
  expected="$2"
  actual="$3"

  if [ "$expected" = "$actual" ]; then
    test_ok "$desc"
  else
    test_not_ok "$desc"
    printf '  expected: %s\n' "$expected" >&2
    printf '  actual:   %s\n' "$actual" >&2
  fi
}

assert_contains() {
  TESTS_RUN=$((TESTS_RUN + 1))
  desc="$1"
  haystack="$2"
  needle="$3"

  case "$haystack" in
    *"$needle"*)
      test_ok "$desc"
      ;;
    *)
      test_not_ok "$desc"
      printf '  expected to contain: %s\n' "$needle" >&2
      ;;
  esac
}

assert_not_contains() {
  TESTS_RUN=$((TESTS_RUN + 1))
  desc="$1"
  haystack="$2"
  needle="$3"

  case "$haystack" in
    *"$needle"*)
      test_not_ok "$desc"
      printf '  expected not to contain: %s\n' "$needle" >&2
      ;;
    *)
      test_ok "$desc"
      ;;
  esac
}

assert_success() {
  TESTS_RUN=$((TESTS_RUN + 1))
  desc="$1"
  shift

  if "$@"; then
    test_ok "$desc"
  else
    rc=$?
    test_not_ok "$desc"
    printf '  command failed with rc=%s: %s\n' "$rc" "$*" >&2
  fi
}

assert_file_exists() {
  TESTS_RUN=$((TESTS_RUN + 1))
  desc="$1"
  path="$2"

  if [ -f "$path" ]; then
    test_ok "$desc"
  else
    test_not_ok "$desc"
    printf '  missing file: %s\n' "$path" >&2
  fi
}

make_temp_dir() {
  dir="$(mktemp -d "/tmp/tailscale_watchdog_test.XXXXXX")" || exit 1
  TEST_TMPDIRS="${TEST_TMPDIRS} ${dir}"
  printf '%s\n' "$dir"
}

cleanup_temp_dirs() {
  for dir in $TEST_TMPDIRS; do
    [ -n "$dir" ] && rm -rf "$dir"
  done
}

finish_tests() {
  cleanup_temp_dirs

  # A file that ran no assertions did not pass; it died before it could fail.
  # This trap fires on EXIT, so it overrides the script's own status -- an
  # `|| exit 1` on a missing fixture, or a `set -u` abort while sourcing the
  # daemon, previously printed "0 tests, 0 failures" and exited 0, and the
  # Makefile counted the file as passed.  That hid a real regression: breaking
  # the order of the state-path assignments in reset_runtime_state aborts this
  # suite's sourcing, and the file reported success.
  if [ "$TESTS_RUN" -eq 0 ]; then
    printf '# 0 tests ran; the file exited before asserting anything\n' >&2
    exit 1
  fi

  if [ "$TESTS_FAILED" -eq 0 ]; then
    printf '# %s tests, 0 failures\n' "$TESTS_RUN"
    exit 0
  fi
  printf '# %s tests, %s failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED" >&2
  exit 1
}

trap finish_tests EXIT INT TERM
