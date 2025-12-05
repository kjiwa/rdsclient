# rdsclient.sh

Connect to RDS instances and Aurora clusters by tag key-value pair using appropriate database clients in Docker containers.

## Requirements

- AWS CLI
- jq
- Docker
- Valid AWS credentials configured

## Usage

```bash
./rdsclient.sh [OPTIONS]
```

### Optional Parameters

- `-t TAG_KEY` - Tag key to filter databases
- `-v TAG_VALUE` - Tag value to filter databases (required if -t is specified)
- `-p PROFILE` - AWS profile name
- `-r REGION` - AWS region (default: us-east-2)
- `-e ENDPOINT_TYPE` - Aurora endpoint type: `reader` or `writer` (default: reader, Aurora only)
- `-a AUTH_TYPE` - Authentication type: `iam`, `secret`, or `manual`
- `-u DB_USER` - Database username (for manual authentication)
- `-w` - Prompt for database password (sets authentication to manual)

**Note:** If `-t` is specified, `-v` must also be specified (and vice versa). If neither is specified, all RDS instances and Aurora clusters in the region are queried.

## Authentication Methods

### Auto-detection (default)
Automatically selects authentication in this order:
1. IAM authentication (if enabled)
2. AWS Secrets Manager (if secret exists)
3. Error if neither available

### IAM Authentication
```bash
./rdsclient.sh -t Environment -v prod -a iam
```
Requires IAM database authentication enabled on the database.

### Secrets Manager Authentication
```bash
./rdsclient.sh -t Environment -v staging -a secret
```
Retrieves credentials from AWS Secrets Manager.

### Manual Authentication
```bash
./rdsclient.sh -t Team -v backend -u myuser -w
```
Prompts for password securely (input not echoed to terminal).

## Supported Database Engines

- PostgreSQL / Aurora PostgreSQL
- MySQL / Aurora MySQL / MariaDB
- Oracle (EE, SE2, with CDB variants)
- SQL Server (EE, SE, EX, Web)

## Examples

Connect to any database:
```bash
./rdsclient.sh -a iam
```

Auto-detect authentication using Environment tag:
```bash
./rdsclient.sh -t Environment -v prod
```

Connect to Aurora writer endpoint with specific profile:
```bash
./rdsclient.sh -t Environment -v staging -p myprofile -e writer
```

Manual authentication with custom user and tag:
```bash
./rdsclient.sh -t Team -v backend -u admin -w
```

Connect to different region:
```bash
./rdsclient.sh -t Environment -v prod -r us-west-2
```

## Behavior

- Queries RDS instances and Aurora clusters (optionally filtered by tag key-value pair)
- Auto-connects if only one database found
- Prompts for selection if multiple databases found
- Endpoint type parameter only valid for Aurora clusters
- Launches appropriate database client in Docker container
- Automatically enables SSL for IAM and Secrets Manager authentication
- Cleans up Docker container on exit

## Exit Codes

- `0` - Successful connection and clean exit
- `1` - Error (missing parameters, database not found, authentication failed, connection failed)
