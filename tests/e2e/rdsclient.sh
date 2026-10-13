#!/bin/sh

# End-to-end tests for rdsclient.sh against the stubbed aws/docker/jq
# toolchain. Multi-match paths are exercised through -i, since the
# interactive prompt reads from /dev/tty (covered by the function-level unit
# tests).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/rds"
STUBS_DIR="$SCRIPT_DIR/../stubs"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_DIR/../lib/harness.sh"
# shellcheck source=../lib/extract.sh
. "$SCRIPT_DIR/../lib/extract.sh"

WORK_DIR="$(mktemp -d)"
STUB_LOG="$WORK_DIR/stub.log"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM HUP

export PATH="$STUBS_DIR:$PATH"
export STUB_LOG

count_calls() {
  # count_calls <program>
  grep -c "^=== $1 ===\$" "$STUB_LOG" 2>/dev/null || true
}

# --- query_databases makes exactly 2 aws calls ---

: >"$STUB_LOG"
TMP_SCRIPT="$WORK_DIR/rdsclient_functions.sh"
load_script_functions "$REPO_DIR/rdsclient.sh" "$TMP_SCRIPT"
set +e
(
  # shellcheck source=/dev/null
  . "$TMP_SCRIPT"
  TAG_COUNT=0
  ENDPOINT_TYPE=""
  FIXTURE_DB_INSTANCES="$FIXTURES_DIR/instances_basic.json"
  FIXTURE_DB_CLUSTERS="$FIXTURES_DIR/clusters_mixed.json"
  export FIXTURE_DB_INSTANCES FIXTURE_DB_CLUSTERS TAG_COUNT ENDPOINT_TYPE
  query_databases >"$WORK_DIR/database_list.txt" 2>/dev/null
)
query_status=$?
set -e
assert_true "query_databases: subshell ran without error" "$query_status"
assert_eq "query_databases: exactly 2 aws calls (describe-instances + describe-clusters)" "2" "$(count_calls aws)"

# --- full run, single postgres instance, IAM auth: no extra describe call ---

printf '{"DBClusters":[]}' >"$WORK_DIR/empty_clusters.json"

: >"$STUB_LOG"
set +e
env \
  FIXTURE_DB_INSTANCES="$FIXTURES_DIR/instances_basic.json" \
  FIXTURE_DB_CLUSTERS="$WORK_DIR/empty_clusters.json" \
  FIXTURE_IAM_TOKEN="tok3n-with a space" \
  "$REPO_DIR/rdsclient.sh" -a iam >"$WORK_DIR/out.log" 2>&1
status=$?
set -e
assert_true "rdsclient -a iam (single match): exits successfully" "$status"
assert_eq "rdsclient -a iam: exactly 3 aws calls (2 describes + 1 auth token)" "3" "$(count_calls aws)"

docker_section=$(awk '/^=== docker ===$/{p=1} p' "$STUB_LOG")
assert_contains "rdsclient -a iam: docker argv forwards PGPASSWORD via -e" "$docker_section" "PGPASSWORD"
assert_not_contains "rdsclient -a iam: password never appears in docker argv" "$docker_section" "tok3n-with a space"
assert_contains "rdsclient -a iam: postgres connect defaults DB name" "$docker_section" "/postgres?sslmode=require"

out_content=$(cat "$WORK_DIR/out.log")
assert_contains "rdsclient -a iam: reports found database" "$out_content" "Found database: standalone-postgres"

# --- Oracle without DatabaseName fails with a clear error ---

: >"$STUB_LOG"
cat >"$WORK_DIR/oracle_instance.json" <<'JSON'
{
  "DBInstances": [
    {
      "DBInstanceIdentifier": "ora-nodbname",
      "Engine": "oracle-se2",
      "Endpoint": {"Address": "ora.example.com", "Port": 1521},
      "DBClusterIdentifier": null,
      "MasterUsername": "admin",
      "IAMDatabaseAuthenticationEnabled": true
    }
  ]
}
JSON
set +e
env \
  FIXTURE_DB_INSTANCES="$WORK_DIR/oracle_instance.json" \
  FIXTURE_DB_CLUSTERS="$WORK_DIR/empty_clusters.json" \
  FIXTURE_IAM_TOKEN="oracletoken" \
  "$REPO_DIR/rdsclient.sh" -a iam >"$WORK_DIR/oracle_out.log" 2>&1
oracle_status=$?
set -e
assert_false "rdsclient: Oracle without DatabaseName fails" "$oracle_status"
assert_contains "rdsclient: Oracle error message is specific" "$(cat "$WORK_DIR/oracle_out.log")" "Oracle requires it to connect"

# --- -i selection on a multi-match list ---
# List order: standalone-postgres, analytics-cluster (writer), analytics-cluster (reader), multiaz-postgres-cluster.

select_database_run() {
  : >"$STUB_LOG"
  run_capture env \
    FIXTURE_DB_INSTANCES="$FIXTURES_DIR/instances_basic.json" \
    FIXTURE_DB_CLUSTERS="$FIXTURES_DIR/clusters_mixed.json" \
    "$REPO_DIR/rdsclient.sh" -a iam -i "$@" </dev/null
}

select_database_run 1
assert_true "rdsclient -i 1: exits successfully" "$RUN_STATUS"
assert_contains "rdsclient -i 1: picks the 1st row" "$RUN_STDOUT" "Found database: standalone-postgres"

select_database_run 3
assert_contains "rdsclient -i 3: picks the 3rd row (cluster reader endpoint)" "$RUN_STDOUT" "analytics-cluster.cluster-ro-abc123"

select_database_run 4
assert_contains "rdsclient -i 4: picks the last row" "$RUN_STDOUT" "Found database: multiaz-postgres-cluster"

select_database_run multiaz-postgres-cluster
assert_true "rdsclient -i ID: exits successfully" "$RUN_STATUS"
assert_contains "rdsclient -i ID: picks the matching row" "$RUN_STDOUT" "Found database: multiaz-postgres-cluster"

select_database_run analytics-cluster
assert_contains "rdsclient -i cluster ID: picks the writer line first" "$RUN_STDOUT" "analytics-cluster.cluster-abc123"

select_database_run 0
assert_false "rdsclient -i 0: rejected" "$RUN_STATUS"
assert_contains "rdsclient -i 0: range error" "$RUN_STDOUT" "database index 0 out of range (1-4)"

select_database_run 5
assert_false "rdsclient -i COUNT+1: rejected" "$RUN_STATUS"
assert_contains "rdsclient -i COUNT+1: range error" "$RUN_STDOUT" "database index 5 out of range (1-4)"
assert_not_contains "rdsclient -i out of range: no docker run" "$(cat "$STUB_LOG")" "=== docker ==="

select_database_run no-such-db
assert_false "rdsclient -i unknown ID: rejected" "$RUN_STATUS"
assert_contains "rdsclient -i unknown ID: not-found error" "$RUN_STDOUT" "database 'no-such-db' not found"

for _bad_selector in a_b 1a -x; do
  select_database_run "$_bad_selector"
  assert_false "rdsclient -i $_bad_selector: malformed selector rejected" "$RUN_STATUS"
done
select_database_run a_b
assert_contains "rdsclient -i a_b: shape error" "$RUN_STDOUT" "Selector must be"
assert_eq "rdsclient -i a_b: rejected before any aws call" "0" "$(count_calls aws)"

select_database_run ""
assert_false "rdsclient -i '': empty selector rejected" "$RUN_STATUS"

# --- -c SQL one-shot mode ---

SQL_TEXT="select 1; select 'a b'"

sql_instance_run() {
  _sql_engine="$1"
  shift
  cat >"$WORK_DIR/sql_instance.json" <<JSON
{
  "DBInstances": [
    {
      "DBInstanceIdentifier": "sql-db",
      "Engine": "$_sql_engine",
      "Endpoint": {"Address": "sql.example.com", "Port": 1234},
      "DBClusterIdentifier": null,
      "MasterUsername": "admin",
      "IAMDatabaseAuthenticationEnabled": true
    }
  ]
}
JSON
  : >"$STUB_LOG"
  run_capture env \
    FIXTURE_DB_INSTANCES="$WORK_DIR/sql_instance.json" \
    FIXTURE_DB_CLUSTERS="$WORK_DIR/empty_clusters.json" \
    FIXTURE_IAM_TOKEN="sqltoken" \
    "$REPO_DIR/rdsclient.sh" -a iam "$@" </dev/null
  SQL_DOCKER=$(awk '/^=== docker ===$/{p=1} p' "$STUB_LOG")
}

sql_instance_run postgres -c "$SQL_TEXT"
assert_true "rdsclient -c postgres: exits successfully" "$RUN_STATUS"
assert_contains "rdsclient -c postgres: passes -c" "$SQL_DOCKER" "-c"
assert_contains "rdsclient -c postgres: SQL is one argv element" "$SQL_DOCKER" "$SQL_TEXT"
assert_not_contains "rdsclient -c postgres: no TTY allocated" "$SQL_DOCKER" "-it"

sql_instance_run mysql -c "$SQL_TEXT"
assert_true "rdsclient -c mysql: exits successfully" "$RUN_STATUS"
assert_contains "rdsclient -c mysql: SQL is one argv element" "$SQL_DOCKER" "$SQL_TEXT"
assert_contains "rdsclient -c mysql: passes -e" "$SQL_DOCKER" "-e
$SQL_TEXT"
assert_not_contains "rdsclient -c mysql: no TTY allocated" "$SQL_DOCKER" "-it"

sql_instance_run sqlserver-se -c "$SQL_TEXT"
assert_true "rdsclient -c sqlserver: exits successfully" "$RUN_STATUS"
assert_contains "rdsclient -c sqlserver: aborts on error and passes -Q" "$SQL_DOCKER" "-b
-Q
$SQL_TEXT"
assert_not_contains "rdsclient -c sqlserver: no TTY allocated" "$SQL_DOCKER" "-it"

sql_instance_run postgres
assert_contains "rdsclient without -c: allocates a TTY" "$SQL_DOCKER" "-it"

sql_instance_run oracle-se2 -c "$SQL_TEXT"
assert_false "rdsclient -c oracle: rejected" "$RUN_STATUS"
assert_contains "rdsclient -c oracle: error message" "$RUN_STDOUT" "-c is not supported for Oracle"
assert_eq "rdsclient -c oracle: rejected before authentication" "2" "$(count_calls aws)"
assert_not_contains "rdsclient -c oracle: no docker run" "$(cat "$STUB_LOG")" "=== docker ==="

sql_instance_run postgres -c ""
assert_false "rdsclient -c '': empty SQL rejected" "$RUN_STATUS"

select_database_run 2 -c "select 1"
assert_true "rdsclient -i 2 -c: exits successfully" "$RUN_STATUS"
assert_contains "rdsclient -i 2 -c: picks the 2nd row" "$RUN_STDOUT" "Found database: analytics-cluster"
assert_contains "rdsclient -i 2 -c: passes the SQL" "$(cat "$STUB_LOG")" "select 1"
assert_not_contains "rdsclient -i 2 -c: no TTY allocated" "$(cat "$STUB_LOG")" "-it"

# --- -h exits 0 ---

set +e
"$REPO_DIR/rdsclient.sh" -h >/dev/null 2>&1
h_status=$?
set -e
assert_eq "rdsclient -h exits 0" "0" "$h_status"

# --- unexpected positional argument rejected ---

set +e
"$REPO_DIR/rdsclient.sh" unexpected-arg >/dev/null 2>&1
extra_status=$?
set -e
assert_false "rdsclient: unexpected positional argument is rejected" "$extra_status"

test_summary
