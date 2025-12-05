#!/bin/sh

set -e

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Required:
  -e ENVIRONMENT    Environment tag value (test, staging, or prod)

Optional:
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -t ENDPOINT_TYPE  Endpoint type for Aurora (reader or writer, default: reader)
  -a AUTH_TYPE      Authentication type (IAM, secrets-manager, or manual)
  -u DB_USER        Database user (optional for manual auth, uses master user if omitted)
  -w DB_PASSWORD    Database password (sets auth to manual if provided)

Examples:
  $0 -e prod -a IAM
  $0 -e staging -p myprofile -r us-west-2 -t writer
  $0 -e test -u myuser -w mypassword
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

validate_environment() {
  [ -z "$ENVIRONMENT" ] && error_exit "Environment parameter (-e) is required"

  case "$ENVIRONMENT" in
  test | staging | prod) ;;
  *) error_exit "Environment must be one of: test, staging, prod" ;;
  esac
}

validate_endpoint_type() {
  [ -z "$ENDPOINT_TYPE" ] && return

  case "$ENDPOINT_TYPE" in
  reader | writer) ;;
  *) error_exit "Endpoint type must be: reader or writer" ;;
  esac
}

validate_auth_parameters() {
  if [ -n "$DB_USER" ] && [ -z "$DB_PASSWORD" ]; then
    error_exit "DB password (-w) must be provided with DB user (-u)"
  fi

  if [ -n "$DB_PASSWORD" ]; then
    if [ -n "$AUTH_TYPE" ] && [ "$AUTH_TYPE" != "manual" ]; then
      error_exit "Cannot specify non-manual authentication type with DB password"
    fi
    AUTH_TYPE="manual"
  fi

  [ -z "$AUTH_TYPE" ] && return

  case "$AUTH_TYPE" in
  IAM | secrets-manager | manual) ;;
  *) error_exit "Authentication type must be: IAM, secrets-manager, or manual" ;;
  esac
}

check_dependencies() {
  command -v aws >/dev/null 2>&1 || error_exit "AWS CLI is not installed"
  command -v jq >/dev/null 2>&1 || error_exit "jq is not installed"
  command -v docker >/dev/null 2>&1 || error_exit "Docker is not installed"
}

build_aws_command() {
  if [ -n "$AWS_PROFILE" ]; then
    AWS_CMD="aws --profile $AWS_PROFILE --region $AWS_REGION --output json"
  else
    AWS_CMD="aws --region $AWS_REGION --output json"
  fi
}

find_rds_resources() {
  echo "Searching for RDS instances with Environment=$ENVIRONMENT..." >&2

  INSTANCES=$($AWS_CMD rds describe-db-instances 2>/dev/null || echo '{"DBInstances":[]}')
  INSTANCES=$(echo "$INSTANCES" | jq "[.DBInstances[] | select(.DBClusterIdentifier == null or .DBClusterIdentifier == \"\") | select(.TagList[]? | select(.Key == \"Environment\" and .Value == \"$ENVIRONMENT\"))]")

  CLUSTERS=$($AWS_CMD rds describe-db-clusters 2>/dev/null || echo '{"DBClusters":[]}')
  CLUSTERS=$(echo "$CLUSTERS" | jq "[.DBClusters[] | select(.TagList[]? | select(.Key == \"Environment\" and .Value == \"$ENVIRONMENT\"))]")

  instance_count=$(echo "$INSTANCES" | jq 'length')
  cluster_count=$(echo "$CLUSTERS" | jq 'length')

  instance_count=${instance_count:-0}
  cluster_count=${cluster_count:-0}
  total_count=$((instance_count + cluster_count))

  if [ "$total_count" -eq 0 ]; then
    error_exit "No RDS instances or Aurora clusters found with Environment=$ENVIRONMENT"
  elif [ "$total_count" -gt 1 ]; then
    error_exit "Multiple RDS instances/clusters found with Environment=$ENVIRONMENT (found $total_count)"
  fi

  INSTANCE_COUNT=$instance_count
  CLUSTER_COUNT=$cluster_count
}

get_db_resource() {
  if [ "$IS_AURORA" = true ]; then
    echo "$CLUSTERS" | jq -r ".[0]$1"
  else
    echo "$INSTANCES" | jq -r ".[0]$1"
  fi
}

extract_database_info() {
  if [ "$INSTANCE_COUNT" -eq 1 ]; then
    IS_AURORA=false
    ENDPOINT=$(get_db_resource '.Endpoint.Address')
    PORT=$(get_db_resource '.Endpoint.Port')
    DB_INSTANCE_ID=$(get_db_resource '.DBInstanceIdentifier')
    DB_NAME=$(get_db_resource '.DBName // "postgres"')

    [ "$ENDPOINT_TYPE" != "reader" ] && error_exit "Endpoint type parameter is only supported for Aurora clusters"
  else
    IS_AURORA=true
    PORT=$(get_db_resource '.Port')
    DB_CLUSTER_ID=$(get_db_resource '.DBClusterIdentifier')
    DB_NAME=$(get_db_resource '.DatabaseName // "postgres"')

    if [ "$ENDPOINT_TYPE" = "writer" ]; then
      ENDPOINT=$(get_db_resource '.Endpoint')
    else
      ENDPOINT=$(get_db_resource '.ReaderEndpoint // .Endpoint')
    fi
  fi

  ENGINE=$(get_db_resource '.Engine')
  MASTER_USER=$(get_db_resource '.MasterUsername')
  IAM_ENABLED=$(get_db_resource '.IAMDatabaseAuthenticationEnabled')
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

get_secret_from_manager() {
  secret_arn=$(get_db_resource '.MasterUserSecret.SecretArn // empty')

  [ -z "$secret_arn" ] && return 1

  secret_value=$($AWS_CMD secretsmanager get-secret-value \
    --secret-id "$secret_arn" \
    --query SecretString \
    --output text) || return 1

  FINAL_USER=$(echo "$secret_value" | jq -r '.username // empty') || return 1
  FINAL_PASSWORD=$(echo "$secret_value" | jq -r '.password // empty') || return 1

  [ -z "$FINAL_USER" ] || [ -z "$FINAL_PASSWORD" ] && return 1
  return 0
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

authenticate_secrets_manager() {
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

  error_exit "No authentication method available. IAM is disabled and no Secrets Manager secret found. Use -a manual with -u and -w to provide credentials"
}

authenticate() {
  case "$AUTH_TYPE" in
  manual) authenticate_manual ;;
  IAM) authenticate_iam ;;
  secrets-manager) authenticate_secrets_manager ;;
  *) authenticate_auto ;;
  esac
}

build_docker_command() {
  CONTAINER_NAME="dbclient-$(date +%s)-$$-$RANDOM"
  trap cleanup EXIT INT TERM

  docker_cmd="docker run --rm -it --name $CONTAINER_NAME"

  if [ -n "$PASSWORD_ENV" ]; then
    docker_cmd="$docker_cmd -e $PASSWORD_ENV=$FINAL_PASSWORD"
  fi

  docker_cmd="$docker_cmd $DOCKER_IMAGE"

  echo "$docker_cmd"
}

connect_postgresql() {
  ssl_mode=""
  [ "$SSL_REQUIRED" = true ] && ssl_mode="sslmode=require"

  docker_cmd=$(build_docker_command)
  $docker_cmd psql "host=$ENDPOINT port=$PORT user=$FINAL_USER dbname=$DB_NAME password=$FINAL_PASSWORD $ssl_mode"
}

connect_mysql() {
  ssl_arg=""
  [ "$SSL_REQUIRED" = true ] && ssl_arg="--ssl-mode=REQUIRED"

  docker_cmd=$(build_docker_command)
  $docker_cmd mysql -h "$ENDPOINT" -P "$PORT" -u "$FINAL_USER" -D "$DB_NAME" "$ssl_arg"
}

connect_oracle() {
  docker_cmd=$(build_docker_command)
  $docker_cmd sqlplus "$FINAL_USER/$FINAL_PASSWORD@//$ENDPOINT:$PORT/$DB_NAME"
}

connect_sqlserver() {
  encrypt_arg=""
  [ "$SSL_REQUIRED" = true ] && encrypt_arg="-N"

  docker_cmd=$(build_docker_command)
  $docker_cmd sqlcmd -S "$ENDPOINT,$PORT" -U "$FINAL_USER" -P "$FINAL_PASSWORD" -d "$DB_NAME" "$encrypt_arg"
}

connect_to_database() {
  echo "Connecting to database as $FINAL_USER..." >&2

  case "$ENGINE" in
  postgres | aurora-postgresql)
    connect_postgresql
    ;;
  mysql | aurora-mysql | mariadb)
    connect_mysql
    ;;
  oracle-ee | oracle-ee-cdb | oracle-se2 | oracle-se2-cdb)
    connect_oracle
    ;;
  sqlserver-ee | sqlserver-se | sqlserver-ex | sqlserver-web)
    connect_sqlserver
    ;;
  esac

  exit $?
}

AWS_PROFILE=""
AWS_REGION="us-east-2"
ENDPOINT_TYPE="reader"
AUTH_TYPE=""
ENVIRONMENT=""
DB_USER=""
DB_PASSWORD=""

while getopts "p:r:t:a:e:u:w:h" opt; do
  case $opt in
  p) AWS_PROFILE="$OPTARG" ;;
  r) AWS_REGION="$OPTARG" ;;
  t) ENDPOINT_TYPE="$OPTARG" ;;
  a) AUTH_TYPE="$OPTARG" ;;
  e) ENVIRONMENT="$OPTARG" ;;
  u) DB_USER="$OPTARG" ;;
  w) DB_PASSWORD="$OPTARG" ;;
  h) usage ;;
  *) usage ;;
  esac
done

validate_environment
validate_endpoint_type
validate_auth_parameters
check_dependencies
build_aws_command
find_rds_resources
extract_database_info
determine_database_type
authenticate
connect_to_database
