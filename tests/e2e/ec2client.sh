#!/bin/sh

# End-to-end tests for ec2client.sh against the stubbed aws/ssh/jq toolchain.
# Multi-match paths are exercised through -i (the interactive prompt reads
# from /dev/tty).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/ec2"
STUBS_DIR="$SCRIPT_DIR/../stubs"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_DIR/../lib/harness.sh"

WORK_DIR="$(mktemp -d)"
STUB_LOG="$WORK_DIR/stub.log"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM HUP

export PATH="$STUBS_DIR:$PATH"
export STUB_LOG

count_calls() {
  grep -c "^=== $1 ===\$" "$STUB_LOG" 2>/dev/null || true
}

# --- single match, SSH: exactly 1 aws call, no eval, ip/user forwarded ---

: >"$STUB_LOG"
set +e
env FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" \
  "$REPO_DIR/ec2client.sh" -c ssh >"$WORK_DIR/ssh_out.log" 2>&1
ssh_status=$?
set -e
assert_true "ec2client -c ssh (single match): exits successfully" "$ssh_status"
assert_eq "ec2client -c ssh: exactly 1 aws call" "1" "$(count_calls aws)"

ssh_section=$(awk '/^=== ssh ===$/{p=1} p' "$STUB_LOG")
assert_contains "ec2client -c ssh: ssh argv targets the instance IP" "$ssh_section" "ec2-user@198.51.100.5"
assert_contains "ec2client -c ssh: agent forwarding requested" "$ssh_section" "-A"

# --- single match, SSM: exactly 1 aws call for the query (session start not logged as aws) ---

: >"$STUB_LOG"
set +e
env FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" \
  "$REPO_DIR/ec2client.sh" -c ssm >"$WORK_DIR/ssm_out.log" 2>&1
ssm_status=$?
set -e
assert_true "ec2client -c ssm (single match): exits successfully" "$ssm_status"
assert_eq "ec2client -c ssm: exactly 2 aws calls (describe-instances + ssm start-session)" "2" "$(count_calls aws)"

# --- -s with non-terminal stdin runs via ssm send-command ---

run_remote() {
  : >"$STUB_LOG"
  set +e
  env FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" "$@" \
    "$REPO_DIR/ec2client.sh" -c ssm -s "uptime" >"$WORK_DIR/remote_out.log" 2>"$WORK_DIR/remote_err.log" </dev/null
  RUN_STATUS=$?
  set -e
}

run_remote
assert_true "ec2client -s (non-terminal): exits successfully" "$RUN_STATUS"
remote_log=$(cat "$STUB_LOG")
assert_contains "ec2client -s: targets the instance" "$remote_log" "--instance-ids
i-0single00000000000"
assert_contains "ec2client -s: uses AWS-RunShellScript" "$remote_log" "AWS-RunShellScript"
assert_contains "ec2client -s: sends the command" "$remote_log" '{"commands":["uptime"]}'
assert_not_contains "ec2client -s: no interactive session" "$remote_log" "start-session"

run_remote FIXTURE_SSM_INVOCATION='{"Status":"Success","ResponseCode":0,"StandardOutputContent":"hello\n","StandardErrorContent":"warn\n"}'
assert_eq "ec2client -s: stdout forwarded" "hello" "$(cat "$WORK_DIR/remote_out.log")"
assert_contains "ec2client -s: stderr forwarded" "$(cat "$WORK_DIR/remote_err.log")" "warn"

run_remote FIXTURE_SSM_INVOCATION='{"Status":"Failed","ResponseCode":3,"StandardOutputContent":"","StandardErrorContent":""}'
assert_eq "ec2client -s: remote exit status propagated" "3" "$RUN_STATUS"

run_remote FIXTURE_SSM_INVOCATION='{"Status":"InProgress","ResponseCode":-1,"StandardOutputContent":"","StandardErrorContent":""}'
assert_false "ec2client -s: unfinished command fails" "$RUN_STATUS"
assert_contains "ec2client -s: unfinished command message" "$(cat "$WORK_DIR/remote_err.log")" "still InProgress"

run_remote FIXTURE_SSM_INVOCATION='{"Status":"TimedOut","ResponseCode":-1,"StandardOutputContent":"","StandardErrorContent":""}'
assert_false "ec2client -s: timed-out command fails" "$RUN_STATUS"
assert_contains "ec2client -s: timed-out command message" "$(cat "$WORK_DIR/remote_err.log")" "ended with status TimedOut"

# --- command mode does not need session-manager-plugin ---

mkdir "$WORK_DIR/bin_noplugin"
ln -s "$STUBS_DIR/aws" "$WORK_DIR/bin_noplugin/aws"
ln -s "$(command -v jq)" "$WORK_DIR/bin_noplugin/jq"
ln -s "$(command -v sh)" "$WORK_DIR/bin_noplugin/sh"
for _tool in cat grep sed awk sort cut head tr; do
  ln -s "$(command -v "$_tool")" "$WORK_DIR/bin_noplugin/$_tool"
done
run_capture env PATH="$WORK_DIR/bin_noplugin" FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" \
  "$REPO_DIR/ec2client.sh" -c ssm -s "uptime" </dev/null
assert_true "ec2client -s (non-terminal): session-manager-plugin not required" "$RUN_STATUS"

run_capture env PATH="$WORK_DIR/bin_noplugin" FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" \
  "$REPO_DIR/ec2client.sh" -c ssm </dev/null
assert_false "ec2client interactive ssm: session-manager-plugin required" "$RUN_STATUS"
assert_contains "ec2client interactive ssm: plugin error" "$RUN_STDOUT" "session-manager-plugin"

# --- -s is rejected with -c ssh ---

run_capture "$REPO_DIR/ec2client.sh" -c ssh -s "uptime" </dev/null
assert_false "ec2client -s with -c ssh: rejected" "$RUN_STATUS"
assert_contains "ec2client -s with -c ssh: error message" "$RUN_STDOUT" "-s applies only to -c ssm"

# --- tag value with spaces is preserved as a single --filters argument ---

: >"$STUB_LOG"
set +e
env FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" \
  "$REPO_DIR/ec2client.sh" -t "Name=Web Server" -c ssm >"$WORK_DIR/space_out.log" 2>&1
space_status=$?
set -e
assert_true "ec2client -t with spaces (single match): exits successfully" "$space_status"
aws_section=$(awk '/^=== aws ===$/{p=1} p' "$STUB_LOG")
assert_contains "ec2client: tag value with spaces stays one filter argument" "$aws_section" "Name=tag:Name,Values=Web Server"

# --- comma in tag value is rejected (EC2 filter syntax treats it as OR) ---

set +e
"$REPO_DIR/ec2client.sh" -t "Name=a,b" -c ssm >"$WORK_DIR/comma_out.log" 2>&1
comma_status=$?
set -e
assert_false "ec2client: comma in tag value is rejected" "$comma_status"
assert_contains "ec2client: comma rejection error message" "$(cat "$WORK_DIR/comma_out.log")" "','"

# --- None fields are normalized: single instance with no name/ip ---

: >"$STUB_LOG"
printf 'i-0noname00000000000\tNone\tNone\n' >"$WORK_DIR/instance_none.tsv"
set +e
env FIXTURE_EC2_INSTANCES="$WORK_DIR/instance_none.tsv" \
  "$REPO_DIR/ec2client.sh" -c ssh >"$WORK_DIR/none_out.log" 2>&1
none_status=$?
set -e
assert_false "ec2client: instance without a public IP fails cleanly over SSH" "$none_status"
none_out=$(cat "$WORK_DIR/none_out.log")
assert_not_contains "ec2client: no literal 'None' leaks into user-facing output" "$none_out" "None"
assert_contains "ec2client: reports missing public IP" "$none_out" "does not have a public IP"

# --- -i selection on a multi-match list (LC_ALL=C sorts: i-0fedcba..., Web Server, api-server-01) ---

select_instance_run() {
  : >"$STUB_LOG"
  run_capture env LC_ALL=C FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instances_mixed.tsv" \
    "$REPO_DIR/ec2client.sh" -c ssm -i "$1" </dev/null
}

select_instance_run 2
assert_true "ec2client -i 2: exits successfully" "$RUN_STATUS"
assert_contains "ec2client -i 2: picks the 2nd sorted row" "$(cat "$STUB_LOG")" "i-0123456789abcdef0"

select_instance_run 1
assert_contains "ec2client -i 1: picks the 1st sorted row" "$(cat "$STUB_LOG")" "i-0fedcba987654321"

select_instance_run 3
assert_contains "ec2client -i 3: picks the last sorted row" "$(cat "$STUB_LOG")" "i-0a1b2c3d4e5f6g7h8"

select_instance_run i-0fedcba987654321
assert_true "ec2client -i ID: exits successfully" "$RUN_STATUS"
assert_contains "ec2client -i ID: picks the matching row" "$(cat "$STUB_LOG")" "i-0fedcba987654321"

select_instance_run 0
assert_false "ec2client -i 0: rejected" "$RUN_STATUS"
assert_contains "ec2client -i 0: range error" "$RUN_STDOUT" "instance index 0 out of range (1-3)"

select_instance_run 4
assert_false "ec2client -i COUNT+1: rejected" "$RUN_STATUS"
assert_contains "ec2client -i COUNT+1: range error" "$RUN_STDOUT" "instance index 4 out of range (1-3)"
assert_not_contains "ec2client -i out of range: no session started" "$(cat "$STUB_LOG")" "start-session"

select_instance_run i-0abc
assert_false "ec2client -i unknown ID: rejected" "$RUN_STATUS"
assert_contains "ec2client -i unknown ID: not-found error" "$RUN_STDOUT" "instance 'i-0abc' not found"

for _bad_selector in i- web-a a_b; do
  select_instance_run "$_bad_selector"
  assert_false "ec2client -i $_bad_selector: malformed selector rejected" "$RUN_STATUS"
  assert_contains "ec2client -i $_bad_selector: shape error" "$RUN_STDOUT" "Selector must be"
  assert_eq "ec2client -i $_bad_selector: rejected before any aws call" "0" "$(count_calls aws)"
done

select_instance_run ""
assert_false "ec2client -i '': empty selector rejected" "$RUN_STATUS"

# --- -h exits 0 ---

set +e
"$REPO_DIR/ec2client.sh" -h >/dev/null 2>&1
h_status=$?
set -e
assert_eq "ec2client -h exits 0" "0" "$h_status"

# --- unexpected positional argument rejected ---

set +e
"$REPO_DIR/ec2client.sh" unexpected-arg >/dev/null 2>&1
extra_status=$?
set -e
assert_false "ec2client: unexpected positional argument is rejected" "$extra_status"

test_summary
