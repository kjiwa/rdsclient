#!/bin/sh

set -eu

AWS_PROFILE=""
AWS_REGION="us-east-2"
ENDPOINT_TYPE=""
AUTH_TYPE=""
TAG_KEY=""
TAG_VALUE=""
DB_USER=""
DB_PASSWORD=""
CONTAINER_NAME=""
TAB=$'\t'

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Optional:
  -t TAG_KEY        Tag key to filter databases
  -v TAG_VALUE      Tag value to filter databases
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -e ENDPOINT_TYPE  Aurora endpoint type (reader or writer)
  -a AUTH_TYPE      Authentication type (iam, secret, or manual)
  -u DB_USER        Database user (sets auth to manual)
  -w                Prompt for database password (sets auth to manual)

Note: If -t is specified, -v must also be specified (and vice versa)

Examples:
  $0
  $0 -t Environment -v prod -a iam
  $0 -t Environment -v staging -e writer
  $0 -u myuser -w
EOF
  exit 1
}

error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

cleanup() {
  if [ -n "$CONTAINER_NAME" ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

read_password() {
  printf "Enter database password: " >&2
  stty -echo 2>/dev/null || true
  read -r password_input </dev/tty
  stty echo 2>/dev/null || true
  echo "" >&2

  [ -z "$password_input" ] && error_exit "Password cannot be empty"

  DB_PASSWORD="$password_input"
}

parse_options() {
  while getopts "p:r:e:a:t:v:u:wh" opt; do
    case $opt in
    p) AWS_PROFILE="$OPTARG" ;;
    r) AWS_REGION="$OPTARG" ;;
    e) ENDPOINT_TYPE="$OPTARG" ;;
    a) AUTH_TYPE="$OPTARG" ;;
    t) TAG_KEY="$OPTARG" ;;
    v) TAG_VALUE="$OPTARG" ;;
    u) DB_USER="$OPTARG" ;;
    w) read_password ;;
    h) usage ;;
    *) usage ;;
    esac
  done
}

validate_tag() {
  if [ -n "$TAG_KEY" ] || [ -n "$TAG_VALUE" ]; then
    if [ -z "$TAG_KEY" ] || [ -z "$TAG_VALUE" ]; then
      error_exit "Both tag key (-t) and tag value (-v) must be provided together"
    fi
  fi
}

validate_endpoint_type() {
  if [ -n "$ENDPOINT_TYPE" ]; then
    case "$ENDPOINT_TYPE" in
    reader | writer) ;;
    *) error_exit "Endpoint type must be: reader or writer" ;;
    esac
  fi
}

validate_auth_type() {
  if [ -n "$DB_USER" ] || [ -n "$DB_PASSWORD" ]; then
    if [ -n "$AUTH_TYPE" ] && [ "$AUTH_TYPE" != "manual" ]; then
      error_exit "Cannot specify non-manual auth type with database user or password"
    fi
    AUTH_TYPE="manual"
  fi

  if [ -n "$AUTH_TYPE" ]; then
    case "$AUTH_TYPE" in
    iam | secret | manual) ;;
    *) error_exit "Authentication type must be: iam, secret, or manual" ;;
    esac
  fi
}

validate_parameters() {
  validate_tag
  validate_endpoint_type
  validate_auth_type
}

check_dependencies() {
  for tool in aws jq docker; do
    command -v "$tool" >/dev/null 2>&1 || error_exit "'$tool' is required but not found"
  done
}

build_aws_command() {
  if [ -n "$AWS_PROFILE" ]; then
    AWS_CMD="aws --profile $AWS_PROFILE --region $AWS_REGION --output json"
  else
    AWS_CMD="aws --region $AWS_REGION --output json"
  fi
}

filter_by_tag() {
  json_data="$1"
  resource_type="$2"

  if [ -n "$TAG_KEY" ]; then
    echo "$json_data" | jq "[.$resource_type[] | select(.TagList[]? | select(.Key == \"$TAG_KEY\" and .Value == \"$TAG_VALUE\"))]"
  else
    echo "$json_data" | jq ".$resource_type"
  fi
}

query_databases() {
  if [ -n "$TAG_KEY" ]; then
    echo "Searching for databases with $TAG_KEY=$TAG_VALUE..." >&2
  else
    echo "Searching for all databases..." >&2
  fi

  instances_json=$($AWS_CMD rds describe-db-instances 2>/dev/null || echo '{"DBInstances":[]}')
  clusters_json=$($AWS_CMD rds describe-db-clusters 2>/dev/null || echo '{"DBClusters":[]}')

  filtered_instances=$(filter_by_tag "$instances_json" "DBInstances")
  filtered_clusters=$(filter_by_tag "$clusters_json" "DBClusters")

  standalone=$(echo "$filtered_instances" | jq '[.[] | select(.DBClusterIdentifier == null or .DBClusterIdentifier == "")] | sort_by(.DBInstanceIdentifier)')
  clusters=$(echo "$filtered_clusters" | jq 'sort_by(.DBClusterIdentifier)')

  DATABASE_LIST=""

  echo "$standalone" | jq -r '.[] | [.DBInstanceIdentifier, .Engine, .Endpoint.Address, "rds", "n/a"] | @tsv' | while IFS="$(printf '\t')" read -r id engine endpoint type ep_type; do
    DATABASE_LIST="${DATABASE_LIST}${id}${TAB}${engine}${TAB}${endpoint}${TAB}${type}${TAB}${ep_type}
"
  done >/tmp/rdsclient_list_$$

  if [ -z "$ENDPOINT_TYPE" ] || [ "$ENDPOINT_TYPE" = "writer" ]; then
    echo "$clusters" | jq -r '.[] | [.DBClusterIdentifier, .Engine, .Endpoint, "aurora", "writer"] | @tsv' | while IFS="$(printf '\t')" read -r id engine endpoint type ep_type; do
      echo "${id}${TAB}${engine}${TAB}${endpoint}${TAB}${type}${TAB}${ep_type}" >>/tmp/rdsclient_list_$$
    done
  fi

  if [ -z "$ENDPOINT_TYPE" ] || [ "$ENDPOINT_TYPE" = "reader" ]; then
    echo "$clusters" | jq -r '.[] | select(.ReaderEndpoint != null) | [.DBClusterIdentifier, .Engine, .ReaderEndpoint, "aurora", "reader"] | @tsv' | while IFS="$(printf '\t')" read -r id engine endpoint type ep_type; do
      echo "${id}${TAB}${engine}${TAB}${endpoint}${TAB}${type}${TAB}${ep_type}" >>/tmp/rdsclient_list_$$
    done
  fi

  DATABASE_LIST=$(cat /tmp/rdsclient_list_$$ 2>/dev/null || echo "")
  rm -f /tmp/rdsclient_list_$$

  if [ -z "$DATABASE_LIST" ]; then
    if [ -n "$TAG_KEY" ]; then
      error_exit "No databases found with $TAG_KEY=$TAG_VALUE"
    else
      error_exit "No databases found"
    fi
  fi
}

display_databases() {
  echo "" >&2
  i=1
  echo "$DATABASE_LIST" | while IFS="$(printf '\t')" read -r id engine endpoint type ep_type; do
    if [ -n "$id" ]; then
      if [ "$type" = "aurora" ]; then
        echo "$i. [Aurora-$ep_type] $id ($engine): $endpoint" >&2
      else
        echo "$i. [RDS] $id ($engine): $endpoint" >&2
      fi
      i=$((i + 1))
    fi
  done
  echo "" >&2
}

select_database() {
  count=$(echo "$DATABASE_LIST" | grep -c . || echo "0")

  if [ "$count" -eq 0 ]; then
    error_exit "No databases found"
  elif [ "$count" -eq 1 ]; then
    echo "Connecting to database..." >&2
    selection=1
  else
    display_databases

    while :; do
      printf "Select database (1-$count): " >&2
      read -r selection </dev/tty || exit 1

      if [ "$selection" -ge 1 ] 2>/dev/null && [ "$selection" -le "$count" ] 2>/dev/null; then
        break
      fi

      echo "ERROR: Invalid selection" >&2
    done
  fi

  SELECTED_LINE=$(echo "$DATABASE_LIST" | sed -n "${selection}p")
  DB_IDENTIFIER=$(echo "$SELECTED_LINE" | cut -f1)
  ENGINE=$(echo "$SELECTED_LINE" | cut -f2)
  ENDPOINT=$(echo "$SELECTED_LINE" | cut -f3)
  DB_TYPE=$(echo "$SELECTED_LINE" | cut -f4)
}

get_database_details() {
  if [ "$DB_TYPE" = "aurora" ]; then
    details=$($AWS_CMD rds describe-db-clusters --db-cluster-identifier "$DB_IDENTIFIER" 2>/dev/null)
    PORT=$(echo "$details" | jq -r '.DBClusters[0].Port')
    DB_NAME=$(echo "$details" | jq -r '.DBClusters[0].DatabaseName')
    MASTER_USER=$(echo "$details" | jq -r '.DBClusters[0].MasterUsername')
    IAM_ENABLED=$(echo "$details" | jq -r '.DBClusters[0].IAMDatabaseAuthenticationEnabled')
    SECRET_ARN=$(echo "$details" | jq -r '.DBClusters[0].MasterUserSecret.SecretArn // empty')
  else
    details=$($AWS_CMD rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" 2>/dev/null)
    PORT=$(echo "$details" | jq -r '.DBInstances[0].Endpoint.Port')
    DB_NAME=$(echo "$details" | jq -r '.DBInstances[0].DBName')
    MASTER_USER=$(echo "$details" | jq -r '.DBInstances[0].MasterUsername')
    IAM_ENABLED=$(echo "$details" | jq -r '.DBInstances[0].IAMDatabaseAuthenticationEnabled')
    SECRET_ARN=$(echo "$details" | jq -r '.DBInstances[0].MasterUserSecret.SecretArn // empty')
  fi

  echo "Found database: $DB_IDENTIFIER ($ENDPOINT:$PORT/$DB_NAME)" >&2
}

determine_client() {
  SSL_REQUIRED=false

  case "$ENGINE" in
  postgres | aurora-postgresql)
    CLIENT_TYPE="PostgreSQL"
    DOCKER_IMAGE="postgres:alpine"
    PASSWORD_ENV="PGPASSWORD"
    ;;
  mysql | aurora-mysql | mariadb)
    CLIENT_TYPE="MySQL/MariaDB"
    DOCKER_IMAGE="mysql:latest"
    PASSWORD_ENV="MYSQL_PWD"
    ;;
  oracle-ee | oracle-ee-cdb | oracle-se2 | oracle-se2-cdb)
    CLIENT_TYPE="Oracle"
    DOCKER_IMAGE="container-registry.oracle.com/database/instantclient:latest"
    PASSWORD_ENV=""
    ;;
  sqlserver-ee | sqlserver-se | sqlserver-ex | sqlserver-web)
    CLIENT_TYPE="SQL Server"
    DOCKER_IMAGE="mcr.microsoft.com/mssql-tools"
    PASSWORD_ENV=""
    ;;
  *)
    error_exit "Unsupported database engine: $ENGINE"
    ;;
  esac
}

authenticate_manual() {
  FINAL_USER="${DB_USER:-$MASTER_USER}"
  FINAL_PASSWORD="$DB_PASSWORD"
}

authenticate_iam() {
  echo "Generating IAM authentication token..." >&2

  SSL_REQUIRED=true
  FINAL_USER="$MASTER_USER"
  FINAL_PASSWORD=$($AWS_CMD rds generate-db-auth-token \
    --hostname "$ENDPOINT" \
    --port "$PORT" \
    --username "$MASTER_USER" \
    --output text)
}

authenticate_secret() {
  [ -z "$SECRET_ARN" ] && error_exit "No AWS Secrets Manager secret found for this database"

  echo "Retrieving credentials from AWS Secrets Manager..." >&2
  secret_value=$($AWS_CMD secretsmanager get-secret-value \
    --secret-id "$SECRET_ARN" \
    --query SecretString \
    --output text 2>/dev/null)

  SSL_REQUIRED=true
  FINAL_USER=$(echo "$secret_value" | jq -r '.username // empty')
  FINAL_PASSWORD=$(echo "$secret_value" | jq -r '.password // empty')
  [ -z "$FINAL_USER" ] || [ -z "$FINAL_PASSWORD" ] && error_exit "Failed to parse credentials from Secrets Manager"
}

authenticate_auto() {
  echo "Auto-detecting authentication method..." >&2
  if [ "$IAM_ENABLED" = "true" ]; then
    AUTH_TYPE="iam"
  elif [ -n "$SECRET_ARN" ]; then
    AUTH_TYPE="secret"
  else
    error_exit "No authentication method available. Use -a manual with -u and -w"
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

connect_to_postgresql() {
  ssl_mode=""
  [ "$SSL_REQUIRED" = true ] && ssl_mode="?sslmode=require"
  PGPASSWORD="$FINAL_PASSWORD" $docker_cmd psql "postgresql://$FINAL_USER@$ENDPOINT:$PORT/$DB_NAME$ssl_mode"
}

connect_to_mysql() {
  ssl_arg=""
  [ "$SSL_REQUIRED" = true ] && ssl_arg="--ssl-mode=REQUIRED"
  MYSQL_PWD="$FINAL_PASSWORD" $docker_cmd mysql -h "$ENDPOINT" -P "$PORT" -u "$FINAL_USER" -D "$DB_NAME" $ssl_arg
}

connect_to_oracle() {
  $docker_cmd sqlplus "$FINAL_USER/$FINAL_PASSWORD@//$ENDPOINT:$PORT/$DB_NAME"
}

connect_to_sqlserver() {
  encrypt_arg=""
  [ "$SSL_REQUIRED" = true ] && encrypt_arg="-N"
  $docker_cmd sqlcmd -S "$ENDPOINT,$PORT" -U "$FINAL_USER" -P "$FINAL_PASSWORD" -d "$DB_NAME" $encrypt_arg
}

connect_database() {
  echo "Connecting to $DB_IDENTIFIER as $FINAL_USER..." >&2

  CONTAINER_NAME="dbclient-$(date +%s)-$$"
  trap cleanup EXIT INT TERM

  docker_cmd="docker run --rm -it --name $CONTAINER_NAME"
  if [ -n "$PASSWORD_ENV" ]; then
    docker_cmd="$docker_cmd -e $PASSWORD_ENV"
  fi
  docker_cmd="$docker_cmd $DOCKER_IMAGE"

  case "$ENGINE" in
  postgres | aurora-postgresql) connect_to_postgresql ;;
  mysql | aurora-mysql | mariadb) connect_to_mysql ;;
  oracle-ee | oracle-ee-cdb | oracle-se2 | oracle-se2-cdb) connect_to_oracle ;;
  sqlserver-ee | sqlserver-se | sqlserver-ex | sqlserver-web) connect_to_sqlserver ;;
  esac

  exit $?
}

main() {
  parse_options "$@"
  validate_parameters
  check_dependencies
  build_aws_command
  query_databases
  select_database
  get_database_details
  determine_client
  authenticate
  connect_database
}

main "$@"
