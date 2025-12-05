# rdsclient.sh

Connect to RDS instances and Aurora clusters by environment tag using appropriate database clients in Docker containers.

## Requirements

- AWS CLI
- jq
- Docker
- Valid AWS credentials configured

## Usage

```bash
./rdsclient.sh -e <environment> [OPTIONS]
```

### Required Parameters

- `-e ENVIRONMENT` - Environment tag value (must be: test, staging, or prod)

### Optional Parameters

- `-p PROFILE` - AWS profile name
- `-r REGION` - AWS region (default: us-east-2)
- `-t ENDPOINT_TYPE` - Aurora endpoint type: `reader` or `writer` (default: reader, Aurora only)
- `-a AUTH_TYPE` - Authentication type: `iam`, `secret`, or `manual`
- `-u DB_USER` - Database username (for manual authentication)
- `-w` - Prompt for database password (sets authentication to manual)

## Authentication Methods

### Auto-detection (default)
Automatically selects authentication in this order:
1. IAM authentication (if enabled)
2. AWS Secrets Manager (if secret exists)
3. Error if neither available

### IAM Authentication
```bash
./rdsclient.sh -e prod -a iam
```
Requires IAM database authentication enabled on the database.

### Secrets Manager Authentication
```bash
./rdsclient.sh -e staging -a secret
```
Retrieves credentials from AWS Secrets Manager.

### Manual Authentication
```bash
./rdsclient.sh -e test -u myuser -w
```
Prompts for password securely (input not echoed to terminal).

## Supported Database Engines

- PostgreSQL / Aurora PostgreSQL
- MySQL / Aurora MySQL / MariaDB
- Oracle (EE, SE2, with CDB variants)
- SQL Server (EE, SE, EX, Web)

## Examples

Auto-detect authentication for production:
```bash
./rdsclient.sh -e prod
```

Connect to Aurora writer endpoint with specific profile:
```bash
./rdsclient.sh -e staging -p myprofile -t writer
```

Manual authentication with custom user:
```bash
./rdsclient.sh -e test -u admin -w
```

Connect to different region:
```bash
./rdsclient.sh -e prod -r us-west-2
```

## Behavior

- Finds exactly one RDS instance or Aurora cluster with matching Environment tag
- Errors if zero or multiple databases found
- Endpoint type parameter only valid for Aurora clusters
- Launches appropriate database client in Docker container
- Automatically enables SSL for IAM and Secrets Manager authentication
- Cleans up Docker container on exit

## Exit Codes

- `0` - Successful connection and clean exit
- `1` - Error (missing parameters, database not found, authentication failed, connection failed)
