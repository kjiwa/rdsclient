# rdsclient

[![CI](https://github.com/kjiwa/rdsclient/actions/workflows/ci.yml/badge.svg)](https://github.com/kjiwa/rdsclient/actions/workflows/ci.yml)

Connect to any RDS or Aurora database with one command. rdsclient discovers databases by tag, detects how to authenticate (IAM, Secrets Manager, or password prompt), launches the right client for the engine in Docker, and connects over SSL — no stored passwords, no local database clients.

![rdsclient demo](demo/demo.gif)

## Why

Connecting to a database in AWS usually means looking up the endpoint in the console, checking which authentication it uses, generating an IAM token or fetching a secret by hand, and keeping psql, mysql, sqlplus, or sqlcmd installed locally. rdsclient collapses all of that into:

```
$ rdsclient -t Environment=production
Searching for databases with 1 tag filter...

1. [Cluster] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-abc.us-east-2.rds.amazonaws.com
2. [Cluster] analytics-cluster (aurora-postgresql): analytics-cluster.cluster-ro-abc.us-east-2.rds.amazonaws.com
3. [RDS] reports-db (postgres): reports-db.ghi789.us-east-2.rds.amazonaws.com

Select database (1-3): 1
Auto-detecting authentication method...
Connecting to analytics-cluster as admin...
```

With a single match it connects immediately — no prompt.

## Features

- Tag-based discovery with AND logic (`-t Environment=prod -t Application=api`)
- Non-interactive use: `-i` selects a database by index or identifier, `-c SQL` runs one statement and exits
- Authentication auto-detection: IAM → Secrets Manager → interactive password prompt
- Standalone RDS instances, Aurora clusters (reader/writer endpoints), and Multi-AZ DB clusters
- Database clients run in Docker — nothing to install locally
- SSL/TLS on by default
- Passwords are never stored, logged, or exposed in process argv
- Single POSIX shell script (sh, dash, bash, zsh) with no dependencies beyond the AWS CLI and Docker

## Supported Databases

| Engine | Client | Auth Support |
|--------|--------|--------------|
| PostgreSQL / Aurora PostgreSQL (standalone, Aurora, or Multi-AZ cluster) | psql | IAM, Secret, Manual |
| MySQL / Aurora MySQL / MariaDB (standalone, Aurora, or Multi-AZ cluster) | mysql | IAM, Secret, Manual |
| Oracle (EE, SE2, CDB variants) | sqlplus | Manual password entry only — see [README-rdsclient.md](README-rdsclient.md) |
| SQL Server (EE, SE, EX, Web) | sqlcmd | IAM, Secret, Manual |

## Quick Start

Prerequisites: Docker, the AWS CLI, and AWS credentials with `rds:DescribeDBInstances` / `rds:DescribeDBClusters` (plus `rds-db:connect` for IAM auth or `secretsmanager:GetSecretValue` for Secrets Manager auth).

Don't have the AWS CLI installed? Install the bundled [awsenv](README-awsenv.md) wrapper scripts and Docker becomes the *only* prerequisite — see [Also Included](#also-included).

```bash
git clone https://github.com/kjiwa/rdsclient.git
cd rdsclient

# Run directly
./rdsclient.sh -t Environment=staging

# Or install system-wide (also installs awsenv, ec2client, and AWS CLI wrappers)
sudo ./install.sh -d /usr/local/bin -c bash

# Or per-user, no sudo
./install.sh -d ~/.local/bin -c bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

```
rdsclient [OPTIONS]

Options:
  -t TAG=VALUE      Tag filter (repeatable, AND logic)
  -i INDEX|ID       Select database by 1-based list index or identifier
  -e ENDPOINT_TYPE  Aurora/cluster endpoint: reader or writer
  -a AUTH_TYPE      Authentication: iam, secret, or manual
  -c SQL            Run SQL non-interactively and exit (not supported for Oracle)
  -u DB_USER        Database user (sets auth to manual unless -a is also given)
  -s SSL_MODE       Use SSL: true or false (default: true)
  -h                Show help

Examples:
  rdsclient
  rdsclient -t Environment=prod
  rdsclient -t Environment=prod -t Application=api -a iam
  rdsclient -t Environment=staging -e writer
  rdsclient -t Environment=prod -i 1 -a iam -c "select now()"
  rdsclient -u myuser -a manual
```

Profile and region come entirely from the AWS CLI's own resolution (`AWS_PROFILE`, `AWS_REGION`/`AWS_DEFAULT_REGION`, `~/.aws/config`). Select a profile with `export AWS_PROFILE=...` before running.

### Authentication Methods

- **Auto-detect (default)** — priority: IAM → Secrets Manager → manual prompt.
- **IAM** (`-a iam`) — generates a temporary 15-minute token; requires IAM database authentication enabled on the database and `rds-db:connect` permission. No stored credentials.
- **Secrets Manager** (`-a secret`) — retrieves credentials from AWS Secrets Manager (used automatically when the database has a `MasterUserSecret`); supports rotation.
- **Manual** (`-a manual`) — interactive password prompt; the password is not stored or logged.

Full details — `-u` semantics, per-engine `DatabaseName` defaults, Oracle password handling, tag syntax edge cases — are in [README-rdsclient.md](README-rdsclient.md).

## Also Included

Two companion tools live in this repo, sharing the same design: single POSIX script, tag-based UX, stub-tested.

- **[awsenv](README-awsenv.md)** — run the AWS CLI (and your own scripts) in Docker with credentials, SSO, TTY handling, and package installation managed for you. Installing its wrapper scripts (`aws`, `aws_completer`, `session-manager-plugin`) makes Docker the only thing rdsclient needs on the host.
- **[ec2client](README-ec2client.md)** — connect to EC2 instances via SSM or SSH with the same `-t Tag=Value` filtering and interactive picker as rdsclient, plus `-i` selection and remote commands without a terminal.

## Installation Details

The install script copies all three tools to the target directory without the `.sh` extension, creates AWS CLI wrapper scripts (`aws`, `aws_completer`, `session-manager-plugin`) backed by awsenv, and optionally configures bash or zsh completion.

```bash
sudo ./install.sh -d /usr/local/bin -c bash   # system-wide
./install.sh -d ~/.local/bin -c zsh           # per-user
```

Manual installation, if you'd rather not run the script:

```bash
sudo cp rdsclient.sh /usr/local/bin/rdsclient
sudo cp ec2client.sh /usr/local/bin/ec2client
sudo cp awsenv.sh /usr/local/bin/awsenv
sudo chmod +x /usr/local/bin/{rdsclient,ec2client,awsenv}

# AWS CLI wrappers backed by awsenv
for cmd in aws aws_completer session-manager-plugin; do
  sudo tee /usr/local/bin/$cmd > /dev/null << 'EOF'
#!/bin/sh
exec "/usr/local/bin/awsenv" "$(basename "$0")" "$@"
EOF
  sudo chmod +x /usr/local/bin/$cmd
done
```

Shell completion (bash: `complete -C aws_completer aws` in `~/.bashrc`; zsh needs `bashcompinit` loaded first — see [README-awsenv.md](README-awsenv.md)).

To uninstall:

```bash
sudo rm -f /usr/local/bin/{awsenv,ec2client,rdsclient,aws,aws_completer,session-manager-plugin}
```

**Note**: rdsclient cannot run *inside* an awsenv container (`awsenv rdsclient ...`) — it launches Docker containers itself, which would require Docker-in-Docker. Use the installed wrapper scripts instead; rdsclient then runs on the host and calls `aws` through the wrapper.

## Testing

A fixture-based test suite in [tests/](tests/) stubs `aws`, `docker`, `ssh`, and `session-manager-plugin`, so it never touches real AWS accounts or Docker. It includes shellcheck and a shared-code drift check:

```bash
./tests/run.sh
```

The demo GIF above is generated from the same stub harness — see [demo/](demo/).

## Support & Maintenance

Maintained on a best-effort basis. Issues and PRs are welcome; responses are not guaranteed. Bug reports that follow the issue template (exact command, OS, Docker version, sanitized output) are far more likely to be acted on. CI (shellcheck, shfmt, and the full stub suite) must pass before anything merges.

## License

[MIT](LICENSE)
