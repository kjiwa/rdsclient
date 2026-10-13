# rdsclient (full reference)

Connect to RDS and Aurora databases with automatic authentication detection. Supports IAM, Secrets Manager, and manual authentication.

This is the complete reference; for the overview, quick start, and installation, see the [main README](README.md).

## Features

- Multiple tag-based filtering with AND logic
- Auto-connects with single match
- Non-interactive selection (`-i`) and one-shot SQL (`-c`)
- Auto-detection of authentication methods
- Standalone RDS instances, Aurora clusters (reader/writer endpoints), and Multi-AZ DB clusters
- Multiple authentication types
- SSL/TLS connections (configurable)
- Docker-based clients (no local installation)

## Prerequisites

- **AWS CLI**
- **Docker**
- **AWS credentials** with appropriate permissions
  - `rds:DescribeDBInstances` and `rds:DescribeDBClusters` for querying databases
  - `rds-db:connect` for IAM authentication
  - `secretsmanager:GetSecretValue` for Secrets Manager authentication

## Supported Databases

| Engine | Client | Auth Support |
|--------|--------|--------------|
| PostgreSQL / Aurora PostgreSQL (standalone, Aurora, or Multi-AZ cluster) | psql | IAM, Secret, Manual |
| MySQL / Aurora MySQL / MariaDB (standalone, Aurora, or Multi-AZ cluster) | mysql | IAM, Secret, Manual |
| Oracle (EE, SE2, CDB variants) | sqlplus | Manual password entry only — see note below |
| SQL Server (EE, SE, EX, Web) | sqlcmd | IAM, Secret, Manual |

All clients run in Docker containers with SSL enabled by default.

**Oracle password entry**: no shell inside the Oracle instant client container can safely receive a password via argv or environment for `sqlplus`, so rdsclient lets `sqlplus` itself prompt for the password on the attached terminal, regardless of `-a`. With `-a secret`, rdsclient retrieves the secret from Secrets Manager but does not display or forward it automatically — look it up separately (e.g. `aws secretsmanager get-secret-value`) and paste it in when `sqlplus` prompts.

## Usage

```
rdsclient.sh [OPTIONS]

Options:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -i INDEX|ID       Select database by 1-based list index or identifier
  -e ENDPOINT_TYPE  Aurora/cluster endpoint: reader or writer
  -a AUTH_TYPE      Authentication: iam, secret, or manual
  -c SQL            Run SQL non-interactively and exit (not supported for Oracle)
  -u DB_USER        Database user (sets auth to manual unless -a is also given)
  -s SSL_MODE       Use SSL: true or false (default: true)
  -h                Show help

Environment Variables:
  AWS_PROFILE, AWS_REGION, AWS_DEFAULT_REGION
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN

Examples:
  rdsclient.sh
  rdsclient.sh -t Environment=prod
  rdsclient.sh -t Environment=prod -t Application=api -a iam
  rdsclient.sh -t Environment=staging -e writer
  rdsclient.sh -t Environment=prod -i my-database
  rdsclient.sh -t Environment=prod -i 1 -a iam -c "select now()"
  rdsclient.sh -u myuser -a manual
  rdsclient.sh -t Environment=dev -s false
```

Profile and region come entirely from the AWS CLI's own resolution: `AWS_PROFILE`, `AWS_REGION`/`AWS_DEFAULT_REGION`, and `~/.aws/config`. Select a profile with `export AWS_PROFILE=...` before running rdsclient.

**`-u` semantics**: passing `-u DB_USER` alone selects manual authentication (equivalent to `-u DB_USER -a manual`) unless `-a` is also given explicitly, in which case `-u` supplies the connecting username for that auth method too — e.g. `-u appuser -a iam` generates an IAM token for `appuser` rather than the database's master user.

**`DatabaseName` defaults**: RDS instances/clusters may not have a `DatabaseName` set. rdsclient handles this per engine:
- PostgreSQL/Aurora PostgreSQL: defaults to the `postgres` database
- MySQL/Aurora MySQL/MariaDB: connects without selecting a database
- SQL Server: connects without selecting a database
- Oracle: `DatabaseName` is the connect descriptor's service name and is required; rdsclient errors out if it's missing

## Authentication Methods

### Auto-detect (Default)

**Priority:** IAM $\rightarrow$ Secrets Manager $\rightarrow$ Manual prompt.

### IAM (Identity and Access Management)

* Generates a **temporary token (15 minutes)** for connection.
* **No stored credentials** (token is temporary).
* Database must have **IAM database authentication enabled**.
* IAM user/role must have the `rds-db:connect` permission.
* Corresponding database user must be configured for IAM.

### Secrets Manager

* Retrieves credentials from **AWS Secrets Manager**.
* Supports automatic credential rotation.
* Used automatically if a `MasterUserSecret` is configured for the database.
* Database must have an associated secret in Secrets Manager.
* IAM user/role must have the `secretsmanager:GetSecretValue` permission.

### Manual

* Uses an **interactive password prompt**.
* Password is **not stored or logged**.

## Non-interactive use

`-i INDEX|ID` skips the picker. A number selects by the 1-based menu position; anything else is an exact match on the database identifier. An out-of-range index or unknown identifier is an error.

`-c SQL` runs the statement without a TTY and exits: `psql -c`, `mysql -e`, or `sqlcmd -b -Q`. The SQL is passed as one argument. Oracle is rejected.

```bash
# Select by identifier
./rdsclient.sh -t Environment=prod -i my-database

# Select by menu position and run a statement
./rdsclient.sh -t Environment=prod -i 1 -a iam -c "select now()"
```

`-c` is fully non-interactive with `-a iam` or `-a secret`; manual authentication still prompts for the password on the terminal.

An Aurora cluster identifier matches its writer line first. Add `-e reader` to select the reader endpoint.

## Tag Filtering

### Syntax
- Format: `-t key=value`
- Multiple filters: `-t key1=value1 -t key2=value2`
- Logic: All tags must match (AND operation)

### Character Handling
- First `=` separates key from value
- Values can contain `=`: `-t Config=key=value` → key: `Config`, value: `key=value`
- Keys with `=` not supported (extremely rare in practice)
- Use quotes for spaces: `-t Name='Production DB'`
- Tag matching is case-sensitive

## Examples

### Basic Usage

```
$ ./rdsclient.sh -t Environment=production -t Application=analytics
Searching for databases with 2 tag filters...

1. [Cluster] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-abc.us-east-2.rds.amazonaws.com
2. [Cluster] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-ro-abc.us-east-2.rds.amazonaws.com
3. [RDS] reports-db (postgres): reports-db.ghi789.us-east-2.rds.amazonaws.com

Select database (1-3): 1
Auto-detecting authentication method...
Connecting to analytics-cluster as admin...
```

### Auto-Authentication

```bash
# All databases
./rdsclient.sh

# Single tag filter
./rdsclient.sh -t Environment=production

# Multiple tag filters (AND logic)
./rdsclient.sh -t Environment=production -t Application=api

# Writer endpoint only with multiple tags
./rdsclient.sh -t Application=analytics -t Team=data -e writer
```

### Specify Authentication

```bash
# IAM authentication with multiple tags
./rdsclient.sh -t Environment=prod -t Name=main-db -a iam

# Manual authentication
./rdsclient.sh -u appuser -a manual

# Secrets Manager with tag filter
./rdsclient.sh -t Application=api -a secret
```

### Aurora Endpoints

```bash
# Writer only with multiple tags
./rdsclient.sh -t Environment=prod -t Application=web -e writer

# Reader only with multiple tags
./rdsclient.sh -t Environment=prod -t Team=analytics -e reader

# Both endpoints (default)
./rdsclient.sh -t Environment=prod
```

### Multiple Tag Combinations

```bash
# Two tags
./rdsclient.sh -t Environment=prod -t Application=api

# Three tags for precise filtering
./rdsclient.sh -t Environment=prod -t Application=web -t Region=us-east-1

# Tags with special characters
./rdsclient.sh -t Team=backend-api -t Owner='Platform Team'

# Tags with equals sign
./rdsclient.sh -t Team=backend-api -t Config=pool=enabled
```

### Disable SSL

```bash
./rdsclient.sh -t Environment=dev -s false
```
