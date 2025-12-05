#!/bin/sh

set -eu

AWS_PROFILE=""
AWS_REGION="us-east-2"
ENDPOINT_TYPE="reader"
ENDPOINT_TYPE_EXPLICIT=false
AUTH_TYPE=""
ENVIRONMENT=""
DB_USER=""
DB_PASSWORD=""
CONTAINER_NAME=""

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Required:
  -e ENVIRONMENT    Environment tag value

Optional:
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -t ENDPOINT_TYPE  Endpoint type for Aurora (reader or writer, default: reader)
  -a AUTH_TYPE      Authentication type (iam, secret, or manual)
  -u DB_USER        Database user (optional for manual auth)
  -w                Prompt for database password (sets auth to manual)

Examples:
  $0 -e prod -a iam
  $0 -e staging -p myprofile -r us-west-2 -t writer
  $0 -e test -u myuser -w
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
  while getopts "p:r:t:a:e:u:wh" opt; do
    case $opt in
    p) AWS_PROFILE="$OPTARG" ;;
    r) AWS_REGION="$OPTARG" ;;
    t)
      ENDPOINT_TYPE="$OPTARG"
      ENDPOINT_TYPE_EXPLICIT=true
      ;;
    a) AUTH_TYPE="$OPTARG" ;;
    e) ENVIRONMENT="$OPTARG" ;;
    u) DB_USER="$OPTARG" ;;
    w) read_password ;;
    h) usage ;;
    *) usage ;;
    esac
  done
}

validate_environment() {
  [ -z "$ENVIRONMENT" ] && error_exit "Environment parameter (-e) is required"

  case "$ENVIRONMENT" in
  test | staging | prod) ;;
  *) error_exit "Environment must be one of: test, staging, prod" ;;
  esac
}

validate_endpoint_type() {
  [ "$ENDPOINT_TYPE_EXPLICIT" = false ] && return 0

  case "$ENDPOINT_TYPE" in
  reader | writer) ;;
  *) error_exit "Endpoint type must be: reader or writer" ;;
  esac
}

validate_auth_parameters() {
  if [ -n "$DB_USER" ] && [ -z "$DB_PASSWORD" ]; then
    error_exit "Password (-w) must be provided with database user (-u)"
  fi

  if [ -n "$DB_PASSWORD" ]; then
    if [ -n "$AUTH_TYPE" ] && [ "$AUTH_TYPE" != "manual" ]; then
      error_exit "Cannot specify non-manual authentication type with password"
    fi
    AUTH_TYPE="manual"
  fi

  [ -z "$AUTH_TYPE" ] && return 0

  case "$AUTH_TYPE" in
  iam | secret | manual) ;;
  *) error_exit "Authentication type must be: iam, secret, or manual" ;;
  esac
}

validate_all_parameters() {
  validate_environment
  validate_endpoint_type
  validate_auth_parameters
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

query_rds_instances() {
  $AWS_CMD rds describe-db-instances 2>/dev/null || echo '{"DBInstances":[]}'
}

query_rds_clusters() {
  $AWS_CMD rds describe-db-clusters 2>/dev/null || echo '{"DBClusters":[]}'
}

filter_by_environment() {
  json_data="$1"
  resource_type="$2"

  echo "$json_data" | jq "[.$resource_type[] | select(.TagList[]? | select(.Key == \"Environment\" and .Value == \"$ENVIRONMENT\"))]"
}

filter_standalone_instances() {
  instances="$1"
  echo "$instances" | jq '[.[] | select(.DBClusterIdentifier == null or .DBClusterIdentifier == "")]'
}

count_resources() {
  json_data="$1"
  count=$(echo "$json_data" | jq 'length')
  echo "${count:-0}"
}

query_and_filter_resources() {
  echo "Searching for RDS instances with Environment=$ENVIRONMENT..." >&2

  all_instances=$(query_rds_instances)
  filtered_instances=$(filter_by_environment "$all_instances" "DBInstances")
  INSTANCES=$(filter_standalone_instances "$filtered_instances")

  all_clusters=$(query_rds_clusters)
  CLUSTERS=$(filter_by_environment "$all_clusters" "DBClusters")

  INSTANCE_COUNT=$(count_resources "$INSTANCES")
  CLUSTER_COUNT=$(count_resources "$CLUSTERS")
}

validate_resource_count() {
  total_count=$((INSTANCE_COUNT + CLUSTER_COUNT))

  if [ "$total_count" -eq 0 ]; then
    error_exit "No RDS instances or Aurora clusters found with Environment=$ENVIRONMENT"
  elif [ "$total_count" -gt 1 ]; then
    error_exit "Multiple RDS instances/clusters found with Environment=$ENVIRONMENT (found $total_count)"
  fi
}

get_db_resource() {
  field="$1"
  if [ "$IS_AURORA" = true ]; then
    echo "$CLUSTERS" | jq -r ".[0]$field"
  else
    echo "$INSTANCES" | jq -r ".[0]$field"
  fi
}

extract_basic_info() {
  if [ "$INSTANCE_COUNT" -eq 1 ]; then
    IS_AURORA=false
    DB_INSTANCE_ID=$(get_db_resource '.DBInstanceIdentifier')
    DB_NAME=$(get_db_resource '.DBName // "postgres"')
  else
    IS_AURORA=true
    DB_CLUSTER_ID=$(get_db_resource '.DBClusterIdentifier')
    DB_NAME=$(get_db_resource '.DatabaseName // "postgres"')
  fi

  PORT=$(get_db_resource '.Port // .Endpoint.Port')
  ENGINE=$(get_db_resource '.Engine')
  MASTER_USER=$(get_db_resource '.MasterUsername')
  IAM_ENABLED=$(get_db_resource '.IAMDatabaseAuthenticationEnabled')
}

select_endpoint() {
  if [ "$IS_AURORA" = false ]; then
    if [ "$ENDPOINT_TYPE_EXPLICIT" = true ]; then
      error_exit "Endpoint type parameter is only supported for Aurora clusters"
    fi
    ENDPOINT=$(get_db_resource '.Endpoint.Address')
  else
    if [ "$ENDPOINT_TYPE" = "writer" ]; then
      ENDPOINT=$(get_db_resource '.Endpoint')
    else
      ENDPOINT=$(get_db_resource '.ReaderEndpoint // .Endpoint')
    fi
  fi
}

extract_database_info() {
  extract_basic_info
  select_endpoint
}

determine_database_type() {
  SSL_REQUIRED=false

  case "$ENGINE" in
  postgres | aurora-postgresql)
    DB_TYPE="PostgreSQL"
    DOCKER_IMAGE="postgres:alpine"
    PASSWORD_ENV="PGPASSWORD"
    ;;
  mysql | aurora-mysql | mariadb)
    DB_TYPE="MySQL/MariaDB"
    DOCKER_IMAGE="mysql:latest"
    PASSWORD_ENV="MYSQL_PWD"
    ;;
  oracle-ee | oracle-ee-cdb | oracle-se2 | oracle-se2-cdb)
    DB_TYPE="Oracle"
    DOCKER_IMAGE="container-registry.oracle.com/database/instantclient:latest"
    PASSWORD_ENV=""
    ;;
  sqlserver-ee | sqlserver-se | sqlserver-ex | sqlserver-web)
    DB_TYPE="SQL Server"
    DOCKER_IMAGE="mcr.microsoft.com/mssql-tools"
    PASSWORD_ENV=""
    ;;
  *)
    error_exit "Unsupported database engine: $ENGINE"
    ;;
  esac

  echo "Found $DB_TYPE database: $ENDPOINT:$PORT/$DB_NAME" >&2
}

get_secret_value() {
  secret_arn="$1"
  $AWS_CMD secretsmanager get-secret-value \
    --secret-id "$secret_arn" \
    --query SecretString \
    --output text 2>/dev/null || echo ""
}

parse_secret_credentials() {
  secret_value="$1"
  username=$(echo "$secret_value" | jq -r '.username // empty' 2>/dev/null)
  password=$(echo "$secret_value" | jq -r '.password // empty' 2>/dev/null)

  [ -z "$username" ] || [ -z "$password" ] && return 1

  FINAL_USER="$username"
  FINAL_PASSWORD="$password"
  return 0
}

get_secret_from_manager() {
  secret_arn=$(get_db_resource '.MasterUserSecret.SecretArn // empty')
  [ -z "$secret_arn" ] && return 1

  secret_value=$(get_secret_value "$secret_arn")
  [ -z "$secret_value" ] && return 1

  parse_secret_credentials "$secret_value"
}

authenticate_iam() {
  FINAL_USER="$MASTER_USER"
  SSL_REQUIRED=true
  echo "Generating IAM authentication token..." >&2

  FINAL_PASSWORD=$($AWS_CMD rds generate-db-auth-token \
    --hostname "$ENDPOINT" \
    --port "$PORT" \
    --username "$MASTER_USER" \
    --output text)

  echo "Using IAM authentication" >&2
}

authenticate_secret() {
  echo "Retrieving credentials from AWS Secrets Manager..." >&2

  if ! get_secret_from_manager; then
    error_exit "No AWS Secrets Manager secret found for this database"
  fi

  SSL_REQUIRED=true
  echo "Using AWS Secrets Manager authentication" >&2
}

authenticate_manual() {
  FINAL_USER="${DB_USER:-$MASTER_USER}"
  FINAL_PASSWORD="$DB_PASSWORD"
  echo "Using manual authentication as $FINAL_USER" >&2
}

authenticate_auto() {
  echo "Auto-detecting authentication method..." >&2

  if [ "$IAM_ENABLED" = "true" ]; then
    authenticate_iam
    return
  fi

  if get_secret_from_manager; then
    echo "Using AWS Secrets Manager authentication" >&2
    return
  fi

  error_exit "No authentication method available. Use -a manual with -u and -w"
}

authenticate() {
  case "$AUTH_TYPE" in
  manual) authenticate_manual ;;
  iam) authenticate_iam ;;
  secret) authenticate_secret ;;
  *) authenticate_auto ;;
  esac
}

build_docker_command() {
  CONTAINER_NAME="dbclient-$(date +%s)-$$"
  trap cleanup EXIT INT TERM

  docker_cmd="docker run --rm -it --name $CONTAINER_NAME"

  if [ -n "$PASSWORD_ENV" ]; then
    docker_cmd="$docker_cmd -e $PASSWORD_ENV"
  fi

  docker_cmd="$docker_cmd $DOCKER_IMAGE"

  echo "$docker_cmd"
}

connect_postgresql() {
  ssl_mode=""
  [ "$SSL_REQUIRED" = true ] && ssl_mode="?sslmode=require"

  docker_cmd=$(build_docker_command)

  if [ -n "$PASSWORD_ENV" ]; then
    PGPASSWORD="$FINAL_PASSWORD" $docker_cmd psql "postgresql://$FINAL_USER@$ENDPOINT:$PORT/$DB_NAME$ssl_mode"
  else
    $docker_cmd psql "postgresql://$FINAL_USER:$FINAL_PASSWORD@$ENDPOINT:$PORT/$DB_NAME$ssl_mode"
  fi
}

connect_mysql() {
  ssl_arg=""
  [ "$SSL_REQUIRED" = true ] && ssl_arg="--ssl-mode=REQUIRED"

  docker_cmd=$(build_docker_command)

  if [ -n "$PASSWORD_ENV" ]; then
    MYSQL_PWD="$FINAL_PASSWORD" $docker_cmd mysql -h "$ENDPOINT" -P "$PORT" -u "$FINAL_USER" -D "$DB_NAME" $ssl_arg
  else
    $docker_cmd mysql -h "$ENDPOINT" -P "$PORT" -u "$FINAL_USER" -p"$FINAL_PASSWORD" -D "$DB_NAME" $ssl_arg
  fi
}

connect_oracle() {
  docker_cmd=$(build_docker_command)
  $docker_cmd sqlplus "$FINAL_USER/$FINAL_PASSWORD@//$ENDPOINT:$PORT/$DB_NAME"
}

connect_sqlserver() {
  encrypt_arg=""
  [ "$SSL_REQUIRED" = true ] && encrypt_arg="-N"

  docker_cmd=$(build_docker_command)
  $docker_cmd sqlcmd -S "$ENDPOINT,$PORT" -U "$FINAL_USER" -P "$FINAL_PASSWORD" -d "$DB_NAME" $encrypt_arg
}

connect_to_database() {
  echo "Connecting to database as $FINAL_USER..." >&2

  case "$ENGINE" in
  postgres | aurora-postgresql) connect_postgresql ;;
  mysql | aurora-aurora-mysql | mariadb) connect_mysql ;;
  oracle-ee | oracle-ee-cdb | oracle-se2 | oracle-se2-cdb) connect_oracle ;;
  sqlserver-ee | sqlserver-se | sqlserver-ex | sqlserver-web) connect_sqlserver ;;
  esac

  exit $?
}

main() {
  parse_options "$@"
  validate_all_parameters
  check_dependencies
  build_aws_command
  query_and_filter_resources
  validate_resource_count
  extract_database_info
  determine_database_type
  authenticate
  connect_to_database
}

main "$@"
