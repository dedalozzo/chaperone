#!/bin/bash
# test/run.sh: tests for Chaperone. Run them with `make test`.
#
# usage: test/run.sh TEST_APP_BINARY RELEASE_APP_BINARY
#
# TEST_APP_BINARY is the app built with -D CHAPERONE_TESTING, which reads its
# allowlist from $CHAPERONE_TEST_ALLOWLIST, so these tests never read or
# change ~/.config/chaperone/allow. It is run directly, not through `open`:
# that tests everything the app decides (the checks, the spawn, the status
# file, the log, signals) without LaunchServices or Developer Tools. What
# only a real `open` launch can show (the responsible process, the skipped
# scan) is checked by hand, as README.md ("How to verify") describes.
#
# RELEASE_APP_BINARY is the real build: the tests check that it is signed
# with the Hardened Runtime and has no trace of the test hook.
#
# Everything happens in build/test/work, which is recreated on each run.
# Written for /bin/bash 3.2, like the shim.

set -u

app="$1"
release="$2"
here="$(cd "$(dirname "$0")/.." && pwd -P)"
shim="$here/chaperone"

work="$here/build/test/work"
rm -rf "$work"
mkdir -p "$work"
work="$(cd "$work" && pwd -P)"   # the real path, as Chaperone resolves it
chmod 755 "$work"

allowed="$work/allowed"
mkdir -p "$allowed" "$work/outside" "$work/cfg"
chmod 755 "$allowed" "$work/outside" "$work/cfg"
export CHAPERONE_TEST_ALLOWLIST="$work/cfg/allow"
printf '# test allowlist\n%s\n' "$allowed" > "$CHAPERONE_TEST_ALLOWLIST"
chmod 600 "$CHAPERONE_TEST_ALLOWLIST"

st="$work/status"
log="$work/log"
passed=0
failed=0

# --- Helpers -----------------------------------------------------------------

ok() { passed=$((passed + 1)); echo "ok - $1"; }
not_ok() {
    failed=$((failed + 1))
    echo "not ok - $1"
    shift
    for line in "$@"; do echo "    $line"; done
    [ -f "$st" ] && sed 's/^/    status: /' "$st"
}

# Writes an executable script: script PATH BODY...
script() {
    local path="$1"
    shift
    { echo '#!/bin/sh'; printf '%s\n' "$@"; } > "$path"
    chmod 755 "$path"
}

# Runs the app with a fresh status file and log, plus any extra arguments.
run_app() {
    rm -f "$st" "$log"
    "$app" --status "$st" --log "$log" "$@"
}

# The last result line in the status file: exit=N or signal=N.
result() { grep -E '^(exit|signal)=' "$st" 2>/dev/null | tail -n 1; }

# expect_exit DESC CODE ARGS...: the run ends with exit=CODE.
expect_exit() {
    local desc="$1" code="$2"
    shift 2
    run_app "$@"
    if [ "$(result)" = "exit=$code" ] && ! grep -q '^refused=' "$st"; then
        ok "$desc"
    else
        not_ok "$desc" "expected exit=$code"
    fi
}

# expect_refused DESC PATTERN ARGS...: refused, with PATTERN in the reason.
expect_refused() {
    local desc="$1" pattern="$2"
    shift 2
    run_app "$@"
    if [ "$(result)" = "exit=126" ] && grep '^refused=' "$st" | grep -q -- "$pattern"; then
        ok "$desc"
    else
        not_ok "$desc" "expected a refusal matching: $pattern"
    fi
}

mode() { stat -f '%Lp' "$1"; }

# --- Runs that go ahead ------------------------------------------------------

script "$allowed/ok.sh" 'echo "out:$1:$2"' 'echo err >&2' 'exit 3'
expect_exit "an allowed script runs and its exit code is recorded" 3 -- "$allowed/ok.sh" "a b" "-c"
if grep -q '^out:a b:-c$' "$log" && grep -q '^err$' "$log"; then
    ok "arguments reach the script; stdout and stderr go to the log"
else
    not_ok "arguments reach the script; stdout and stderr go to the log" "log: $(cat "$log" 2>/dev/null)"
fi
if grep -q '^app=[0-9][0-9]*$' "$st" && grep -q '^pid=[0-9][0-9]*$' "$st"; then
    ok "the status file has app= and pid= lines"
else
    not_ok "the status file has app= and pid= lines"
fi
if [ "$(mode "$st")" = 600 ] && [ "$(mode "$log")" = 600 ]; then
    ok "new status and log files have mode 0600"
else
    not_ok "new status and log files have mode 0600" "status $(mode "$st"), log $(mode "$log")"
fi

expect_exit "the script is found without -- before it" 3 "$allowed/ok.sh"

script "$allowed/stdin.sh" 'if read -r line; then echo "read:$line"; else echo eof; fi'
expect_exit "stdin is /dev/null" 0 -- "$allowed/stdin.sh" < /etc/hosts
grep -q '^eof$' "$log" && ok "the script reads end-of-file from stdin" \
    || not_ok "the script reads end-of-file from stdin" "log: $(cat "$log")"

script "$allowed/cwd.sh" 'pwd -P'
expect_exit "--cwd sets the working directory" 0 --cwd "$work/outside" -- "$allowed/cwd.sh"
[ "$(cat "$log")" = "$work/outside" ] && ok "the script runs in the --cwd directory" \
    || not_ok "the script runs in the --cwd directory" "log: $(cat "$log")"

ln -s "$allowed/ok.sh" "$allowed/link-in.sh"
expect_exit "a symlink to an allowed script runs" 3 -- "$allowed/link-in.sh"

mkdir -p "$allowed/sticky"
chmod 1777 "$allowed/sticky"
script "$allowed/sticky/x.sh" 'exit 0'
expect_exit "a world-writable directory with the sticky bit (like /tmp) is accepted" 0 -- "$allowed/sticky/x.sh"

printf 'first line\n' > "$work/existing.log"
rm -f "$st"
"$app" --status "$st" --log "$work/existing.log" -- "$allowed/ok.sh"
if [ "$(head -n 1 "$work/existing.log")" = "first line" ] && grep -q '^out:' "$work/existing.log"; then
    ok "an existing log is appended to, not truncated"
else
    not_ok "an existing log is appended to, not truncated"
fi

# --- Refusals ----------------------------------------------------------------

expect_refused "a relative script path is refused" "absolute path" -- ok.sh
expect_refused "a missing script is refused" "cannot resolve" -- "$allowed/missing.sh"
expect_refused "an unknown option is refused" "unknown option" --frobnicate -- "$allowed/ok.sh"
expect_refused "no script is refused" "no script" --cwd /

script "$work/outside/x.sh" 'exit 0'
expect_refused "a script outside the allowlist is refused" "not under a prefix" -- "$work/outside/x.sh"

mkdir -p "${allowed}2"
script "${allowed}2/x.sh" 'exit 0'
expect_refused "a prefix matches whole path components only" "not under a prefix" -- "${allowed}2/x.sh"

ln -s "$work/outside/x.sh" "$allowed/link-out.sh"
expect_refused "a symlink pointing out of the allowlist is refused" "not under a prefix" -- "$allowed/link-out.sh"

script "$allowed/gw.sh" 'exit 0'
chmod 775 "$allowed/gw.sh"
expect_refused "a group-writable script is refused" "group- or world-writable" -- "$allowed/gw.sh"

script "$allowed/noexec.sh" 'exit 0'
chmod 644 "$allowed/noexec.sh"
expect_refused "a script that is not executable is refused" "not executable" -- "$allowed/noexec.sh"

mkdir -p "$allowed/dir.sh"
expect_refused "a directory is refused" "not a regular file" -- "$allowed/dir.sh"

printf 'no shebang line\n' > "$allowed/noshebang.sh"
chmod 755 "$allowed/noshebang.sh"
expect_refused "a script without a #! line is refused" "cannot start" -- "$allowed/noshebang.sh"

mkdir -p "$allowed/open"
chmod 775 "$allowed/open"
script "$allowed/open/x.sh" 'exit 0'
expect_refused "a script inside a group-writable directory is refused" "inside $allowed/open, which is group- or world-writable" -- "$allowed/open/x.sh"

mkdir -p "$allowed/open2/deep"
chmod 757 "$allowed/open2"
script "$allowed/open2/deep/x.sh" 'exit 0'
expect_refused "a world-writable directory higher up is refused too" "inside $allowed/open2, which" -- "$allowed/open2/deep/x.sh"

# --- The allowlist -----------------------------------------------------------

mv "$CHAPERONE_TEST_ALLOWLIST" "$work/allow.saved"
expect_refused "no allowlist refuses everything" "no allowlist" -- "$allowed/ok.sh"
mv "$work/allow.saved" "$CHAPERONE_TEST_ALLOWLIST"

chmod 620 "$CHAPERONE_TEST_ALLOWLIST"
expect_refused "a group-writable allowlist is refused" "allowlist .* is group- or world-writable" -- "$allowed/ok.sh"
chmod 600 "$CHAPERONE_TEST_ALLOWLIST"

chmod 775 "$work/cfg"
expect_refused "an allowlist inside a group-writable directory is refused" "allowlist .* is inside $work/cfg" -- "$allowed/ok.sh"
chmod 755 "$work/cfg"

cp "$CHAPERONE_TEST_ALLOWLIST" "$work/allow.saved"
printf 'relative/path\n/\n%s/\n' "$allowed" > "$CHAPERONE_TEST_ALLOWLIST"
expect_exit "relative lines and / are ignored; a trailing slash is fine" 3 -- "$allowed/ok.sh"
printf 'relative/path\n/\n' > "$CHAPERONE_TEST_ALLOWLIST"
expect_refused "an allowlist of only ignored lines allows nothing" "not under a prefix" -- "$allowed/ok.sh"
mv "$work/allow.saved" "$CHAPERONE_TEST_ALLOWLIST"

# --- Status file and log safety ----------------------------------------------

echo "precious" > "$work/target"
ln -s "$work/target" "$work/status-link"
"$app" --status "$work/status-link" -- "$allowed/ok.sh"
code=$?
if [ "$code" = 126 ] && [ "$(cat "$work/target")" = precious ]; then
    ok "a symlinked status file is refused and its target left alone"
else
    not_ok "a symlinked status file is refused and its target left alone" "app exit $code, target: $(cat "$work/target")"
fi

ln -s "$work/target" "$work/log-link"
rm -f "$st"
"$app" --status "$st" --log "$work/log-link" -- "$allowed/ok.sh"
if [ "$(result)" = "exit=126" ] && grep -q '^refused=cannot open the log .* is a symbolic link$' "$st" \
    && [ "$(cat "$work/target")" = precious ]; then
    ok "a symlinked log is refused and its target left alone"
else
    not_ok "a symlinked log is refused and its target left alone" "target: $(cat "$work/target")"
fi

# --- Signals -----------------------------------------------------------------

script "$allowed/sleep.sh" 'sleep 30 &' 'echo "child=$!"' 'wait'
rm -f "$st" "$log"
"$app" --status "$st" --log "$log" -- "$allowed/sleep.sh" &
app_pid=$!
for _ in $(seq 1 50); do grep -q '^child=' "$log" 2>/dev/null && break; sleep 0.1; done
child="$(sed -n 's/^child=//p' "$log")"
kill -TERM "$app_pid"
wait "$app_pid"
if [ "$(result)" = "signal=15" ]; then
    ok "SIGTERM to the app stops the script and is recorded as signal=15"
else
    not_ok "SIGTERM to the app stops the script and is recorded as signal=15"
fi
if [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null; then
    ok "the signal reaches the script's whole process group"
else
    not_ok "the signal reaches the script's whole process group" "child $child still running"
    [ -n "$child" ] && kill "$child" 2>/dev/null
fi

# --- The release build -------------------------------------------------------

if codesign -dv "$release" 2>&1 | grep -q 'flags=.*runtime'; then
    ok "the release build is signed with the Hardened Runtime"
else
    not_ok "the release build is signed with the Hardened Runtime" "$(codesign -dv "$release" 2>&1 | grep flags)"
fi
if ! grep -a -q CHAPERONE_TEST_ALLOWLIST "$release"; then
    ok "the release build has no test hook"
else
    not_ok "the release build has no test hook"
fi

# --- The shim (only what needs no `open`) ------------------------------------

expect_shim() {
    local desc="$1" code="$2"
    shift 2
    CHAPERONE_APP="$here/build/Chaperone.app" "$shim" "$@" >/dev/null 2>&1
    local got=$?
    [ "$got" = "$code" ] && ok "$desc" || not_ok "$desc" "expected exit $code, got $got"
}
expect_shim "shim: --help exits 0" 0 --help
expect_shim "shim: no script is a usage error" 2
expect_shim "shim: a relative script is a usage error" 2 -- x.sh
expect_shim "shim: an unknown option is a usage error" 2 --frobnicate
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$here/Info.plist")"
if CHAPERONE_APP="$here/build/Chaperone.app" "$shim" --version | grep -q "^chaperone $version "; then
    ok "shim: --version prints the app's version"
else
    not_ok "shim: --version prints the app's version"
fi
ln -s "$work/target" "$work/shim-status-link"
expect_shim "shim: a symlinked --status is a usage error" 2 --status "$work/shim-status-link" -- "$allowed/ok.sh"

# --- Summary -----------------------------------------------------------------

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
