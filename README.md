# rdsclient.sh

Interactive AWS RDS and Aurora database connection tool with multiple authentication methods.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Docker (for database clients)
- jq (JSON processor)
- Appropriate IAM permissions for RDS and Secrets Manager operations

## Usage

```
rdsclient.sh [OPTIONS]

Optional:
  -t TAG_KEY        Tag key to filter databases
  -v TAG_VALUE      Tag value to filter databases
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -e ENDPOINT_TYPE  Aurora endpoint type (reader or writer)
  -a AUTH_TYPE      Authentication type (iam, secret, or manual)
  -u DB_USER        Database user (sets auth to manual)
  -s SSL_MODE       Use SSL connection (true or false, default: true)
```

## Examples

Connect to any database with auto-detected authentication:
```bash
./rdsclient.sh
```

Filter by environment tag:
```bash
./rdsclient.sh -t Environment -v production
```

Connect to Aurora writer endpoint using IAM authentication:
```bash
./rdsclient.sh -t Environment -v staging -e writer -a iam
```

Connect with manual authentication:
```bash
./rdsclient.sh -u appuser -a manual
```

Disable SSL for legacy database:
```bash
./rdsclient.sh -t Environment -v dev -s false
```

## Sample Output

```
Searching for databases with Environment=production...

1. [Aurora] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-abc123.us-east-2.rds.amazonaws.com
2. [Aurora] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-ro-abc123.us-east-2.rds.amazonaws.com
3. [Aurora] app-cluster (aurora-mysql): app-cluster.cluster-def456.us-east-2.rds.amazonaws.com
4. [Aurora] app-cluster (aurora-mysql): app-cluster.cluster-ro-def456.us-east-2.rds.amazonaws.com
5. [RDS] legacy-db (postgres): legacy-db.ghi789.us-east-2.rds.amazonaws.com
6. [RDS] reports-db (mysql): reports-db.jkl012.us-east-2.rds.amazonaws.com

Select database (1-6): 1
Found database: analytics-cluster (analytics-cluster.cluster-abc123.us-east-2.rds.amazonaws.com:5432/analytics)
Auto-detecting authentication method...
Retrieving credentials from AWS Secrets Manager...
Connecting to analytics-cluster as admin...
psql (16.1)
SSL connection (protocol: TLSv1.3, cipher: TLS_AES_256_GCM_SHA384, compression: off)
Type "help" for help.

analytics=> 
```

## Authentication Methods

### Auto-detect (Default)
Automatically selects authentication method:
1. IAM authentication if enabled
2. AWS Secrets Manager if secret exists
3. Manual password prompt otherwise

### IAM
- Generates temporary authentication token
- Requires IAM database authentication enabled
- Token valid for 15 minutes
- No stored credentials needed

### Secrets Manager
- Retrieves credentials from AWS Secrets Manager
- Requires MasterUserSecret configured
- Secure credential storage
- Automatic rotation support

### Manual
- Prompts for password interactively
- Requires username specified with -u flag
- Password not stored or logged

## Supported Database Engines

- PostgreSQL / Aurora PostgreSQL
- MySQL / Aurora MySQL / MariaDB
- Oracle (EE, SE2, CDB variants)
- SQL Server (EE, SE, EX, Web)

## Notes

- Both tag key and tag value must be specified together
- Database clients run in Docker containers
- SSL connections enabled by default
- Auto-cleanup of Docker containers on exit
