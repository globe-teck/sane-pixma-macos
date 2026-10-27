#!/bin/sh
# ok() and nok() always return 0, so 'A && ok || nok' is safe here.
# shellcheck disable=SC2015
# Plain-sh tests for bin/scan, using tests/fake-scanimage. No scanner needed.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/../bin/scan"
PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/scan-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DEV1="pixma:04A9FFFF_EXAMPLE1"
DEV2="pixma:04A9FFFF_EXAMPLE2"

reset() {
  rm -rf "$TMP/out" "$TMP/log"
  export SCANIMAGE="$HERE/fake-scanimage" SANE_PREFIX="$TMP/prefix" SCAN_DIR="$TMP/out" FAKE_LOG="$TMP/log"
  export FAKE_DEVICES="$DEV1" FAKE_FAIL=0 FAKE_EMPTY=0
  unset SANE_CONFIG_DIR DYLD_LIBRARY_PATH || true
}

ok() { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
nok() { FAIL=$((FAIL + 1)); printf 'not ok %s\n' "$1"; [ -n "${2:-}" ] && printf '  # %s\n' "$2"; }

expect_rc() { # name expected_rc actual_rc
  if [ "$2" -eq "$3" ]; then ok "$1"; else nok "$1" "expected exit $2, got $3"; fi
}

t_default_scan() {
  reset
  out="$("$SCAN" 2>"$TMP/err")"; rc=$?
  expect_rc "default scan exits 0" 0 "$rc"
  case "$out" in "$TMP/out/scan-"*.jpg) ok "prints a timestamped .jpg path in SCAN_DIR" ;; *) nok "timestamped path" "$out" ;; esac
  [ "$(cat "$out" 2>/dev/null)" = "FAKEIMAGEDATA" ] && ok "file holds the image data" || nok "file holds the image data"
  grep -q "args:-d $DEV1 --format=jpeg --resolution 300 --mode Color" "$TMP/log" && ok "auto-detected device and defaults passed" || nok "defaults passed" "$(cat "$TMP/log")"
  grep -q "env:DYLD_LIBRARY_PATH=$TMP/prefix/lib SANE_CONFIG_DIR=$TMP/prefix/etc/sane.d" "$TMP/log" && ok "sets DYLD_LIBRARY_PATH and SANE_CONFIG_DIR from SANE_PREFIX" || nok "env vars" "$(cat "$TMP/log")"
  ls "$TMP/out"/*.part >/dev/null 2>&1 && nok "no .part file left" || ok "no .part file left"
}

t_flags() {
  reset
  out="$("$SCAN" -r 600 -m gray -f png -o "$TMP/out/sub")"; rc=$?
  expect_rc "flags scan exits 0" 0 "$rc"
  case "$out" in "$TMP/out/sub/scan-"*.png) ok "png into custom folder" ;; *) nok "png into custom folder" "$out" ;; esac
  grep -q -- "--format=png --resolution 600 --mode Gray" "$TMP/log" && ok "resolution, mode and format passed" || nok "flags passed" "$(cat "$TMP/log")"
}

t_two_scans_same_second() {
  reset
  a="$("$SCAN")"; b="$("$SCAN")"
  [ "$a" != "$b" ] && [ -f "$a" ] && [ -f "$b" ] && ok "two quick scans don't overwrite each other" || nok "no overwrite" "$a $b"
}

t_explicit_device() {
  reset
  FAKE_DEVICES="$DEV1
$DEV2" "$SCAN" -d "$DEV2" >/dev/null; rc=$?
  expect_rc "explicit -d works with two devices" 0 "$rc"
  grep -q "args:-d $DEV2 " "$TMP/log" && ok "uses the chosen device" || nok "uses the chosen device"
}

t_two_devices_needs_choice() {
  reset
  FAKE_DEVICES="$DEV1
$DEV2" "$SCAN" >/dev/null 2>"$TMP/err"; rc=$?
  expect_rc "two devices without -d exits 2" 2 "$rc"
  grep -q "$DEV2" "$TMP/err" && ok "lists the devices to pick from" || nok "lists devices"
}

t_no_device() {
  reset
  FAKE_DEVICES="" "$SCAN" >/dev/null 2>"$TMP/err"; rc=$?
  expect_rc "no device exits 3" 3 "$rc"
  grep -q "no pixma scanner found" "$TMP/err" && ok "clear no-device message" || nok "no-device message" "$(cat "$TMP/err")"
}

t_not_in_scan_mode() {
  reset
  FAKE_FAIL=1 "$SCAN" >/dev/null 2>"$TMP/err"; rc=$?
  expect_rc "failed scan exits 4" 4 "$rc"
  grep -q "scan mode" "$TMP/err" && ok "explains scan mode" || nok "scan mode hint" "$(cat "$TMP/err")"
  grep -q "Error during device I/O" "$TMP/err" && ok "shows scanimage's own error" || nok "shows scanimage error"
  [ -z "$(ls -A "$TMP/out" 2>/dev/null)" ] && ok "no partial file kept after failure" || nok "no partial file" "$(ls "$TMP/out")"
}

t_empty_output() {
  reset
  FAKE_EMPTY=1 "$SCAN" >/dev/null 2>"$TMP/err"; rc=$?
  expect_rc "empty image exits 4" 4 "$rc"
}

t_bad_args() {
  reset
  "$SCAN" -r abc >/dev/null 2>&1; expect_rc "non-numeric resolution exits 2" 2 $?
  "$SCAN" -r 10 >/dev/null 2>&1; expect_rc "too-low resolution exits 2" 2 $?
  "$SCAN" -m Sepia >/dev/null 2>&1; expect_rc "bad mode exits 2" 2 $?
  "$SCAN" -f gif >/dev/null 2>&1; expect_rc "bad format exits 2" 2 $?
  "$SCAN" --bogus >/dev/null 2>&1; expect_rc "unknown option exits 2" 2 $?
  "$SCAN" -r >/dev/null 2>&1; expect_rc "missing value exits 2" 2 $?
}

t_missing_scanimage() {
  reset
  SCANIMAGE="$TMP/nope" "$SCAN" >/dev/null 2>"$TMP/err"; rc=$?
  expect_rc "missing scanimage exits 1" 1 "$rc"
  grep -q "build.sh" "$TMP/err" && ok "points at build.sh" || nok "points at build.sh"
}

t_list_and_help() {
  reset
  "$SCAN" --list | grep -q "device \`$DEV1'" && ok "--list shows scanimage -L output" || nok "--list"
  "$SCAN" --help | grep -q "SCAN_DIR" && ok "--help documents SCAN_DIR" || nok "--help"
}

t_build_script_guards() {
  BUILD="$HERE/../build.sh"
  "$BUILD" --bogus >/dev/null 2>&1; expect_rc "build.sh rejects unknown options" 2 $?
  "$BUILD" --help | grep -q -- "--no-brew" && ok "build.sh --help lists options" || nok "build.sh --help"
  grep -q '^SANE_SHA256="[0-9a-f]\{64\}"\( \|$\)' "$BUILD" && ok "build.sh pins a sha256" || nok "build.sh pins a sha256"
  grep -q -- "--enable-pthread" "$BUILD" && ok "build.sh enables pthread" || nok "build.sh enables pthread"
  grep -q 'BACKENDS="pixma"' "$BUILD" && ok "build.sh builds only pixma" || nok "build.sh builds only pixma"
  if grep -v '^ *#' "$BUILD" | grep -q 'sudo'; then nok "build.sh never calls sudo"; else ok "build.sh never calls sudo"; fi
  if [ "$(uname -s)" != "Darwin" ]; then
    "$BUILD" >/dev/null 2>"$TMP/err"; rc=$?
    expect_rc "build.sh refuses to run off macOS" 1 "$rc"
  fi
}

t_build_script_guards
t_default_scan
t_flags
t_two_scans_same_second
t_explicit_device
t_two_devices_needs_choice
t_no_device
t_not_in_scan_mode
t_empty_output
t_bad_args
t_missing_scanimage
t_list_and_help

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
