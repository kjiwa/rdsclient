#!/bin/sh

# MIT License
#
# Copyright (c) 2025 Kamil Jiwa
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -eu

ENDPOINT_TYPE=""
AUTH_TYPE=""
TAG_KEYS=""
TAG_VALUES=""
TAG_COUNT=0
DB_USER=""
DB_PASSWORD=""
CONTAINER_NAME=""
SSL_MODE="true"
SELECTOR=""
SQL_COMMAND=""

usage() {
  _usage_exit_code="${1:-1}"

  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Optional:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -i INDEX|ID       Select database by 1-based list index or identifier
  -e ENDPOINT_TYPE  Aurora/cluster endpoint type (reader or writer)
  -a AUTH_TYPE      Authentication type (iam, secret, or manual)
  -c SQL            Run SQL non-interactively and exit (not supported for Oracle)
  -u DB_USER        Database user (sets auth to manual unless -a is also given)
  -s SSL_MODE       Use SSL connection (true or false, default: true)
  -h                Show this help message

Environment Variables:
  AWS_PROFILE              AWS profile
  AWS_REGION               AWS region
  AWS_DEFAULT_REGION       AWS region fallback if AWS_REGION not set
  AWS_ACCESS_KEY_ID        AWS access key ID
  AWS_SECRET_ACCESS_KEY    AWS secret access key
  AWS_SESSION_TOKEN        AWS session token for temporary credentials

Profile and region are resolved by the AWS CLI itself from the environment
variables above or from ~/.aws/config; this tool passes no --profile or
--region flags.

Examples:
  $0
  $0 -t Environment=prod
  $0 -t Environment=prod -t Application=api -a iam
  $0 -t Environment=staging -e writer
  $0 -t Environment=prod -i my-database
  $0 -t Environment=prod -i 1 -a iam -c "select now()"
  $0 -u myuser -a manual
  $0 -t Environment=dev -s false
EOF
  exit "$_usage_exit_code"
}

# --- BEGIN SHARED: error_exit ---
error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}
# --- END SHARED: error_exit ---

cleanup() {
  if [ -n "$CONTAINER_NAME" ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

# --- BEGIN SHARED: trim_whitespace ---
trim_whitespace() {
  printf "%s" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
# --- END SHARED: trim_whitespace ---

read_password() {
  printf "Enter database password: " >&2
  stty -echo 2>/dev/null || true
  read -r _read_pwd_input </dev/tty
  stty echo 2>/dev/null || true
  printf "\n" >&2

  [ -z "$_read_pwd_input" ] && error_exit "Password cannot be empty"
  DB_PASSWORD="$_read_pwd_input"
}

# --- BEGIN SHARED: parse_tag_argument ---
parse_tag_argument() {
  _parse_arg="$1"

  case "$_parse_arg" in
  *=*)
    PARSED_KEY="${_parse_arg%%=*}"
    PARSED_VALUE="${_parse_arg#*=}"
    ;;
  *)
    PARSED_KEY=""
    PARSED_VALUE=""
    ;;
  esac
}
# --- END SHARED: parse_tag_argument ---

# --- BEGIN SHARED: validate_tag_format ---
validate_tag_format() {
  _val_original="$1"
  _val_key="$2"
  _val_value="$3"

  [ -z "$_val_key" ] && error_exit "Invalid tag format '$_val_original': must contain '=' character"

  _val_trimmed_key=$(trim_whitespace "$_val_key")
  [ -z "$_val_trimmed_key" ] && error_exit "Invalid tag format '$_val_original': key cannot be empty"
  case "$_val_trimmed_key" in
  *[\$\`\\\"\']*) error_exit "Invalid tag format '$_val_original': key contains unsafe characters" ;;
  esac

  _val_trimmed_value=$(trim_whitespace "$_val_value")
  [ -z "$_val_trimmed_value" ] && error_exit "Invalid tag format '$_val_original': value cannot be empty"
  case "$_val_trimmed_value" in
  *[\$\`\\\"\']*) error_exit "Invalid tag format '$_val_original': value contains unsafe characters" ;;
  esac

  PARSED_KEY="$_val_trimmed_key"
  PARSED_VALUE="$_val_trimmed_value"
}
# --- END SHARED: validate_tag_format ---

# --- BEGIN SHARED: accumulate_tags ---
accumulate_tags() {
  _acc_key="$1"
  _acc_value="$2"

  if [ -z "$TAG_KEYS" ]; then
    TAG_KEYS="$_acc_key"
    TAG_VALUES="$_acc_value"
  else
    TAG_KEYS="$TAG_KEYS
$_acc_key"
    TAG_VALUES="$TAG_VALUES
$_acc_value"
  fi

  TAG_COUNT=$((TAG_COUNT + 1))
}
# --- END SHARED: accumulate_tags ---

# --- BEGIN SHARED: get_tag_at_index ---
get_tag_at_index() {
  _get_idx="$1"
  TAG_KEY_AT_INDEX=$(printf "%s" "$TAG_KEYS" | sed -n "${_get_idx}p")
  TAG_VALUE_AT_INDEX=$(printf "%s" "$TAG_VALUES" | sed -n "${_get_idx}p")
}
# --- END SHARED: get_tag_at_index ---

parse_options() {
  while getopts "e:a:t:i:c:u:s:h" _parse_opt; do
    case "$_parse_opt" in
    e) ENDPOINT_TYPE="$OPTARG" ;;
    a) AUTH_TYPE="$OPTARG" ;;
    t)
      parse_tag_argument "$OPTARG"
      validate_tag_format "$OPTARG" "$PARSED_KEY" "$PARSED_VALUE"
      accumulate_tags "$PARSED_KEY" "$PARSED_VALUE"
      ;;
    i)
      [ -n "$OPTARG" ] || error_exit "Selector cannot be empty"
      SELECTOR="$OPTARG"
      ;;
    c)
      [ -n "$OPTARG" ] || error_exit "SQL command cannot be empty"
      SQL_COMMAND="$OPTARG"
      ;;
    u) DB_USER="$OPTARG" ;;
    s) SSL_MODE="$OPTARG" ;;
    h) usage 0 ;;
    *) usage ;;
    esac
  done

  shift $((OPTIND - 1))
  [ $# -gt 0 ] && error_exit "Unexpected argument: $1"

  return 0
}

apply_user_auth_default() {
  if [ -n "$DB_USER" ] && [ -z "$AUTH_TYPE" ]; then
    AUTH_TYPE="manual"
  fi
}

validate_endpoint_type() {
  [ -n "$ENDPOINT_TYPE" ] || return 0
  case "$ENDPOINT_TYPE" in
  reader | writer) ;;
  *) error_exit "Endpoint type must be: reader or writer" ;;
  esac
}

validate_auth_type() {
  [ -n "$AUTH_TYPE" ] || return 0
  case "$AUTH_TYPE" in
  iam | secret | manual) ;;
  *) error_exit "Authentication type must be: iam, secret, or manual" ;;
  esac
}

validate_ssl_mode() {
  case "$SSL_MODE" in
  true | false) ;;
  *) error_exit "SSL mode must be: true or false" ;;
  esac
}

validate_selector() {
  [ -n "$SELECTOR" ] || return 0
  printf "%s" "$SELECTOR" | grep -Eq '^([0-9]+|[A-Za-z][A-Za-z0-9-]*)$' ||
    error_exit "Selector must be a list index or a database identifier: $SELECTOR"
}

validate_parameters() {
  validate_selector
  validate_endpoint_type
  validate_auth_type
  validate_ssl_mode
}

check_dependencies() {
  for _check_tool in aws jq docker; do
    command -v "$_check_tool" >/dev/null 2>&1 || error_exit "'$_check_tool' is required but not found"
  done
}

build_jq_tag_selector() {
  _jq_key="$1"
  _jq_val="$2"
  printf 'select(.TagList[]? | select(.Key == "%s" and .Value == "%s"))' "$_jq_key" "$_jq_val"
}

build_rds_tag_filter() {
  if [ "$TAG_COUNT" -eq 0 ]; then
    printf ""
    return
  fi

  _filter=""
  _filter_i=1
  while [ "$_filter_i" -le "$TAG_COUNT" ]; do
    get_tag_at_index "$_filter_i"
    _filter_sel=$(build_jq_tag_selector "$TAG_KEY_AT_INDEX" "$TAG_VALUE_AT_INDEX")

    if [ -n "$_filter" ]; then
      _filter="$_filter | "
    fi
    _filter="$_filter$_filter_sel"

    _filter_i=$((_filter_i + 1))
  done

  printf "%s" "$_filter"
}

filter_by_tags() {
  _fbt_json="$1"
  _fbt_resource="$2"

  _fbt_filter=$(build_rds_tag_filter)

  if [ -z "$_fbt_filter" ]; then
    printf "%s" "$_fbt_json" | jq ".$_fbt_resource | sort_by(.DBInstanceIdentifier // .DBClusterIdentifier)"
  else
    printf "%s" "$_fbt_json" | jq ".$_fbt_resource | [.[] | $_fbt_filter] | sort_by(.DBInstanceIdentifier // .DBClusterIdentifier)"
  fi
}

build_tag_display_message() {
  if [ "$TAG_COUNT" -eq 0 ]; then
    printf "all databases"
    return
  fi

  if [ "$TAG_COUNT" -eq 1 ]; then
    get_tag_at_index 1
    printf "databases with %s=%s" "$TAG_KEY_AT_INDEX" "$TAG_VALUE_AT_INDEX"
    return
  fi

  printf "databases with %d tag filters" "$TAG_COUNT"
}

query_databases() {
  _query_msg=$(build_tag_display_message)
  printf "Searching for %s...\n" "$_query_msg" >&2

  _query_inst_json=$(AWSENV_TTY=never aws rds describe-db-instances --output json) ||
    error_exit "Failed to query RDS instances"
  _query_clust_json=$(AWSENV_TTY=never aws rds describe-db-clusters --output json) ||
    error_exit "Failed to query RDS clusters"

  _query_filt_inst=$(filter_by_tags "$_query_inst_json" "DBInstances")
  _query_filt_clust=$(filter_by_tags "$_query_clust_json" "DBClusters")

  DATABASE_LIST=$(
    get_standalone_instances "$_query_filt_inst"
    get_cluster_endpoints "$_query_filt_clust" "$ENDPOINT_TYPE"
  )

  [ -z "$DATABASE_LIST" ] && error_exit "No databases found"

  return 0
}

get_standalone_instances() {
  _standalone_json="$1"

  printf "%s" "$_standalone_json" | jq -r '
    .[] | select(.DBClusterIdentifier == null or .DBClusterIdentifier == "") |
    [
      .DBInstanceIdentifier,
      .Engine,
      .Endpoint.Address,
      "rds",
      (.Endpoint.Port | tostring),
      (.DBName // "-"),
      (.MasterUsername // "-"),
      (if .IAMDatabaseAuthenticationEnabled then "true" else "false" end),
      (.MasterUserSecret.SecretArn // "-")
    ] | @tsv'
}

get_cluster_endpoints() {
  _cluster_json="$1"
  _cluster_ep_type="$2"

  # Only Aurora and Multi-AZ DB clusters go through this code path;
  # docdb/neptune clusters (also returned by describe-db-clusters) are
  # filtered out here since they use unrelated client tooling.
  printf "%s" "$_cluster_json" | jq -r --arg endpoint_type "$_cluster_ep_type" '
    .[] | select(.Engine | IN("aurora-postgresql", "aurora-mysql", "mysql", "postgres")) |
    . as $c |
    (
      (if ($endpoint_type == "" or $endpoint_type == "writer") then
        [[
          $c.DBClusterIdentifier, $c.Engine, $c.Endpoint, "cluster",
          ($c.Port | tostring), ($c.DatabaseName // "-"), ($c.MasterUsername // "-"),
          (if $c.IAMDatabaseAuthenticationEnabled then "true" else "false" end),
          ($c.MasterUserSecret.SecretArn // "-")
        ]]
      else [] end)
      +
      (if ($c.ReaderEndpoint != null) and ($endpoint_type == "" or $endpoint_type == "reader") then
        [[
          $c.DBClusterIdentifier, $c.Engine, $c.ReaderEndpoint, "cluster",
          ($c.Port | tostring), ($c.DatabaseName // "-"), ($c.MasterUsername // "-"),
          (if $c.IAMDatabaseAuthenticationEnabled then "true" else "false" end),
          ($c.MasterUserSecret.SecretArn // "-")
        ]]
      else [] end)
    )[] | @tsv'
}

# --- BEGIN SHARED: count_lines ---
count_lines() {
  _count_text="$1"
  if [ -z "$_count_text" ]; then
    printf "0"
    return
  fi

  printf "%s\n" "$_count_text" | grep -c .
}
# --- END SHARED: count_lines ---

display_databases() {
  printf "\n" >&2
  _disp_db_i=1
  printf "%s\n" "$DATABASE_LIST" | while IFS="$(printf '\t')" read -r _disp_id _disp_engine _disp_endpoint _disp_type _disp_rest; do
    if [ -n "$_disp_id" ]; then
      if [ "$_disp_type" = "cluster" ]; then
        printf "%d. [Cluster] %s (%s): %s\n" "$_disp_db_i" "$_disp_id" "$_disp_engine" "$_disp_endpoint" >&2
      else
        printf "%d. [RDS] %s (%s): %s\n" "$_disp_db_i" "$_disp_id" "$_disp_engine" "$_disp_endpoint" >&2
      fi
      _disp_db_i=$((_disp_db_i + 1))
    fi
  done
  printf "\n" >&2
}

# --- BEGIN SHARED: read_user_selection ---
read_user_selection() {
  _rus_max="$1"
  _rus_noun="$2"

  while true; do
    printf "Select %s (1-%d): " "$_rus_noun" "$_rus_max" >&2
    read -r _rus_selection </dev/tty || exit 1

    case "$_rus_selection" in
    '' | *[!0-9]*)
      printf "ERROR: Invalid selection\n" >&2
      continue
      ;;
    esac

    if [ "$_rus_selection" -ge 1 ] && [ "$_rus_selection" -le "$_rus_max" ]; then
      printf "%s" "$_rus_selection"
      return 0
    fi

    printf "ERROR: Selection must be between 1 and %d\n" "$_rus_max" >&2
  done
}
# --- END SHARED: read_user_selection ---

# --- BEGIN SHARED: resolve_selection ---
resolve_selection() {
  _rs_ids="$1"
  _rs_count="$2"
  _rs_selector="$3"
  _rs_noun="$4"

  case "$_rs_selector" in
  *[!0-9]*)
    _rs_line=$(printf "%s\n" "$_rs_ids" | grep -n -x -F -- "$_rs_selector" | head -n 1 | cut -d: -f1)
    [ -n "$_rs_line" ] || error_exit "$_rs_noun '$_rs_selector' not found"
    printf "%s" "$_rs_line"
    return 0
    ;;
  esac

  if [ "$_rs_selector" -lt 1 ] || [ "$_rs_selector" -gt "$_rs_count" ]; then
    error_exit "$_rs_noun index $_rs_selector out of range (1-$_rs_count)"
  fi

  printf "%s" "$_rs_selector"
}
# --- END SHARED: resolve_selection ---

select_database() {
  _select_db_count=$(count_lines "$DATABASE_LIST")

  if [ -n "$SELECTOR" ]; then
    _select_db_ids=$(printf "%s\n" "$DATABASE_LIST" | cut -f1)
    _select_db_choice=$(resolve_selection "$_select_db_ids" "$_select_db_count" "$SELECTOR" "database")
  elif [ "$_select_db_count" -eq 1 ]; then
    printf "Connecting to database...\n" >&2
    _select_db_choice=1
  else
    display_databases
    _select_db_choice=$(read_user_selection "$_select_db_count" "database")
  fi

  SELECTED_LINE=$(printf "%s" "$DATABASE_LIST" | sed -n "${_select_db_choice}p")
  DB_IDENTIFIER=$(printf "%s" "$SELECTED_LINE" | cut -f1)
  ENGINE=$(printf "%s" "$SELECTED_LINE" | cut -f2)
  ENDPOINT=$(printf "%s" "$SELECTED_LINE" | cut -f3)
}

normalize_placeholder() {
  [ "$1" = "-" ] && return 0
  printf "%s" "$1"
}

get_database_details() {
  PORT=$(printf "%s" "$SELECTED_LINE" | cut -f5)
  DB_NAME=$(normalize_placeholder "$(printf "%s" "$SELECTED_LINE" | cut -f6)")
  MASTER_USER=$(normalize_placeholder "$(printf "%s" "$SELECTED_LINE" | cut -f7)")
  IAM_ENABLED=$(printf "%s" "$SELECTED_LINE" | cut -f8)
  SECRET_ARN=$(normalize_placeholder "$(printf "%s" "$SELECTED_LINE" | cut -f9)")

  [ -z "$PORT" ] && error_exit "Failed to retrieve database port"

  if [ -z "$MASTER_USER" ]; then
    [ -z "$DB_USER" ] && error_exit "Failed to retrieve master username. Specify username with -u"
  fi

  _details_display=""
  [ -n "$DB_NAME" ] && _details_display="/$DB_NAME"
  printf "Found database: %s (%s:%s%s)\n" "$DB_IDENTIFIER" "$ENDPOINT" "$PORT" "$_details_display" >&2
}

determine_client() {
  case "$ENGINE" in
  postgres | aurora-postgresql)
    DOCKER_IMAGE="postgres:alpine"
    PASSWORD_ENV="PGPASSWORD"
    CLIENT="psql"
    ;;
  mysql | aurora-mysql | mariadb)
    DOCKER_IMAGE="mysql:latest"
    PASSWORD_ENV="MYSQL_PWD"
    CLIENT="mysql"
    ;;
  oracle-ee | oracle-ee-cdb | oracle-se2 | oracle-se2-cdb)
    DOCKER_IMAGE="container-registry.oracle.com/database/instantclient:latest"
    PASSWORD_ENV=""
    CLIENT="sqlplus"
    [ -z "$SQL_COMMAND" ] || error_exit "-c is not supported for Oracle (sqlplus prompts for the password)"
    ;;
  sqlserver-ee | sqlserver-se | sqlserver-ex | sqlserver-web)
    DOCKER_IMAGE="mcr.microsoft.com/mssql-tools18/mssql-tools"
    PASSWORD_ENV="SQLCMDPASSWORD"
    CLIENT="sqlcmd"
    ;;
  *)
    error_exit "Unsupported database engine: $ENGINE"
    ;;
  esac
}

authenticate_manual() {
  read_password
  FINAL_USER="${DB_USER:-$MASTER_USER}"
  FINAL_PASSWORD="$DB_PASSWORD"
}

authenticate_iam() {
  printf "Generating IAM authentication token...\n" >&2

  FINAL_USER="${DB_USER:-$MASTER_USER}"
  _auth_token=$(AWSENV_TTY=never aws rds generate-db-auth-token \
    --hostname "$ENDPOINT" \
    --port "$PORT" \
    --username "$FINAL_USER" \
    --output text) || error_exit "Failed to generate IAM authentication token"

  [ -z "$_auth_token" ] && error_exit "Failed to generate IAM authentication token"
  FINAL_PASSWORD="$_auth_token"
}

authenticate_secret() {
  [ -z "$SECRET_ARN" ] && error_exit "No AWS Secrets Manager secret found for this database"

  printf "Retrieving credentials from AWS Secrets Manager...\n" >&2
  _auth_secret_val=$(AWSENV_TTY=never aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ARN" \
    --query SecretString \
    --output text) || error_exit "Failed to retrieve secret from Secrets Manager"

  [ -z "$_auth_secret_val" ] && error_exit "Failed to retrieve secret from Secrets Manager"

  FINAL_USER=$(printf "%s" "$_auth_secret_val" | jq -r '.username // empty')
  FINAL_PASSWORD=$(printf "%s" "$_auth_secret_val" | jq -r '.password // empty')
  if [ -z "$FINAL_USER" ] || [ -z "$FINAL_PASSWORD" ]; then
    error_exit "Failed to parse credentials from Secrets Manager"
  fi

  return 0
}

authenticate_auto() {
  printf "Auto-detecting authentication method...\n" >&2
  if [ "$IAM_ENABLED" = "true" ]; then
    AUTH_TYPE="iam"
  elif [ -n "$SECRET_ARN" ]; then
    AUTH_TYPE="secret"
  else
    AUTH_TYPE="manual"
  fi

  authenticate
}

authenticate() {
  case "$AUTH_TYPE" in
  manual) authenticate_manual ;;
  iam) authenticate_iam ;;
  secret) authenticate_secret ;;
  *) authenticate_auto ;;
  esac
}

run_client() {
  if [ -n "$SQL_COMMAND" ]; then
    docker run --rm --name "$CONTAINER_NAME" "$@"
  else
    docker run --rm -it --name "$CONTAINER_NAME" "$@"
  fi
}

connect_to_postgresql() {
  _pg_db_name="${DB_NAME:-postgres}"
  _pg_url="postgresql://$FINAL_USER@$ENDPOINT:$PORT/$_pg_db_name"
  [ "$SSL_MODE" = "true" ] && _pg_url="$_pg_url?sslmode=require"

  set -- psql
  if [ -n "$SQL_COMMAND" ]; then
    set -- "$@" -c "$SQL_COMMAND"
  fi

  run_client -e "$PASSWORD_ENV" "$DOCKER_IMAGE" "$@" "$_pg_url"
}

connect_to_mysql() {
  set -- mysql -h "$ENDPOINT" -P "$PORT" -u "$FINAL_USER"
  [ -n "$DB_NAME" ] && set -- "$@" -D "$DB_NAME"
  [ "$SSL_MODE" = "true" ] && set -- "$@" --ssl-mode=REQUIRED
  if [ -n "$SQL_COMMAND" ]; then
    set -- "$@" -e "$SQL_COMMAND"
  fi

  run_client -e "$PASSWORD_ENV" "$DOCKER_IMAGE" "$@"
}

connect_to_oracle() {
  # Oracle's DatabaseName maps to the connect descriptor's service name, so
  # unlike the other engines it cannot be defaulted or omitted.
  [ -z "$DB_NAME" ] && error_exit "Failed to retrieve Oracle service name (DatabaseName). Oracle requires it to connect"

  printf "sqlplus will prompt for the password interactively.\n" >&2
  run_client "$DOCKER_IMAGE" \
    sqlplus "$FINAL_USER@//$ENDPOINT:$PORT/$DB_NAME"
}

connect_to_sqlserver() {
  set -- sqlcmd -S "$ENDPOINT,$PORT" -U "$FINAL_USER"
  [ -n "$DB_NAME" ] && set -- "$@" -d "$DB_NAME"

  # sqlcmd encrypts the connection by default; -C trusts the server
  # certificate (needed for RDS's certificate chain). SSL_MODE=false uses
  # -N o to disable encryption while still trusting the cert.
  if [ "$SSL_MODE" = "true" ]; then
    set -- "$@" -C
  else
    set -- "$@" -N o -C
  fi

  if [ -n "$SQL_COMMAND" ]; then
    set -- "$@" -b -Q "$SQL_COMMAND"
  fi

  run_client -e "$PASSWORD_ENV" "$DOCKER_IMAGE" "$@"
}

connect_database() {
  printf "Connecting to %s as %s...\n" "$DB_IDENTIFIER" "$FINAL_USER" >&2

  CONTAINER_NAME="dbclient-$$-$(date +%s%N 2>/dev/null || date +%s)"

  if [ -n "$PASSWORD_ENV" ]; then
    export "$PASSWORD_ENV=$FINAL_PASSWORD"
  fi

  case "$CLIENT" in
  psql) connect_to_postgresql ;;
  mysql) connect_to_mysql ;;
  sqlplus) connect_to_oracle ;;
  sqlcmd) connect_to_sqlserver ;;
  esac
}

main() {
  trap cleanup EXIT INT TERM HUP
  parse_options "$@"
  apply_user_auth_default
  validate_parameters
  check_dependencies
  query_databases
  select_database
  get_database_details
  determine_client
  authenticate
  connect_database
}

main "$@"
