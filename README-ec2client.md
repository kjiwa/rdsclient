# ec2client

Connect to EC2 instances via SSH or SSM. Filter by tags, select interactively, and auto-connect with a single match.

## Features

- Multiple tag-based filtering with AND logic
- Auto-connects with single match
- SSH and SSM connection methods
- Works with private instances (SSM)
- Custom SSM commands
- Non-interactive selection (`-i`) and remote commands without a terminal

## Prerequisites

- **AWS CLI**
- **session-manager-plugin**
- **SSH client**
- **AWS credentials** with appropriate permissions
  - `ec2:DescribeInstances` for querying instances
  - `ssm:StartSession` for SSM connections
  - `ssm:SendCommand` and `ssm:GetCommandInvocation` for non-interactive use

## Usage

```
ec2client.sh [OPTIONS]

Options:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -i INDEX|ID       Select instance by 1-based list index or instance ID
  -c METHOD         Connection method: ssh or ssm (default: ssm)
  -u USER           SSH user (default: ec2-user)
  -k KEYFILE        SSH private key path
  -s COMMAND        SSM command (default: sh). When stdin is not a
                    terminal, runs COMMAND as root via SSM send-command, prints
                    its output, and exits with its status
  -h                Show help

Environment Variables:
  AWS_PROFILE, AWS_REGION, AWS_DEFAULT_REGION
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN

Examples:
  ec2client.sh
  ec2client.sh -t Environment=prod
  ec2client.sh -t Environment=prod -t Team=backend
  ec2client.sh -t Environment=prod -i i-0123456789abcdef0
  ec2client.sh -t Name=bastion -c ssh -k ~/.ssh/key.pem
  ec2client.sh -t Environment=staging -s "cd; bash -l"
```

Profile and region come entirely from the AWS CLI's own resolution: `AWS_PROFILE`, `AWS_REGION`/`AWS_DEFAULT_REGION`, and `~/.aws/config`. Select a profile with `export AWS_PROFILE=...` before running ec2client.

## Connection Methods

### SSM (AWS Systems Manager Session Manager)

* Connects to instances **without public IP** addresses.
* Utilizes the AWS Systems Manager (SSM) service and the **SSM Agent** running on the instance.
* Requires the instance to have an **IAM role with the `AmazonSSMManagedInstanceCore` policy**.
* Starts a **POSIX shell** (default is `sh`, configurable with the `-s` flag).
* Requires the **`session-manager-plugin`** to be installed locally (handled automatically by `awsenv`).
* **Ideal for private VPC instances** with no direct internet access.

### SSH (Secure Shell)

* Connects using the standard Secure Shell protocol.
* Requires the instance to have a **public IP address** or reachable private IP (via VPN, for example).
* Requires a **security group rule allowing inbound traffic on TCP Port 22**.
* Supports **agent forwarding** (using the `-A` flag).

## Non-interactive use

`-i INDEX|ID` skips the picker. A number selects by the 1-based menu position; anything else is an exact match on the instance ID. An out-of-range index or unknown ID is an error.

When `-s` is given and stdin is not a terminal, ec2client does not start a session. It runs COMMAND with `ssm send-command` and the `AWS-RunShellScript` document, prints stdout and stderr, and exits with the remote command's exit status. This mode needs only `aws` and `jq` locally; `session-manager-plugin` is not used. `-s` is rejected with `-c ssh`.

```bash
# Run a command on a selected instance
./ec2client.sh -t Name=web -i 1 -s "df -h" </dev/null

# Select by instance ID
./ec2client.sh -t Environment=prod -i i-0123456789abcdef0 -s "uptime" </dev/null
```

Notes:
- The command runs as root, not `ssm-user`: the SSM Agent runs as root. Any principal allowed to send `AWS-RunShellScript` has root on the instance.
- ec2client waits with `aws ssm wait command-executed`, which polls every 5 seconds for up to 20 checks (about 100 seconds). If the command is still running, ec2client reports its status and prints the `aws ssm get-command-invocation` command to check later.
- `GetCommandInvocation` returns only the first 24,000 characters of stdout and 8,000 of stderr.

## Tag Filtering

### Syntax
- Format: `-t key=value`
- Multiple filters: `-t key1=value1 -t key2=value2`
- Logic: All tags must match (AND operation)

### Character Handling
- First `=` separates key from value
- Values can contain `=`: `-t Config=key=value` → key: `Config`, value: `key=value`
- Keys with `=` not supported (extremely rare in practice)
- Use quotes for spaces: `-t Name='Web Server'`
- Values **cannot** contain `,`: EC2 filters treat a comma inside a `Values=` field as a list separator (logical OR), which would silently contradict the documented exact-match AND semantics of `-t`
- Tag matching is case-sensitive

## Examples

### Basic Usage

```
$ ./ec2client.sh -t Environment=production -t Lifecycle=managed
Searching for EC2 instances with 2 tag filters...

1. api-server-01 (i-0123456789abcdef0): 54.123.45.67
2. api-server-02 (i-0fedcba987654321): 54.123.45.68
3. worker-node-01 (i-0a1b2c3d4e5f6g7h8): no-public-ip

Select instance (1-3): 3
Connecting to i-0a1b2c3d4e5f6g7h8 via SSM...
```

### SSM Connection (Default)

```bash
# All running instances
./ec2client.sh

# Single tag filter
./ec2client.sh -t Environment=production

# Multiple tag filters (AND logic)
./ec2client.sh -t Environment=production -t Team=backend
./ec2client.sh -t Name=web -t Role=api -t Region=us-east-1
```

### SSH Connection

```bash
# With key file
./ec2client.sh -t Name=bastion -c ssh -k ~/.ssh/prod.pem

# Different user with multiple tags
./ec2client.sh -t Environment=prod -t Name=ubuntu-server -c ssh -u ubuntu

# Multiple tags for precise selection
./ec2client.sh -t Team=platform -t Role=bastion -t Environment=prod -c ssh
```

### Custom SSM Commands

```bash
# Start bash login shell
./ec2client.sh -t Name=web -s "bash -l"

# Multiple tags with custom command
./ec2client.sh -t Environment=prod -t Role=worker -s "cd /var/log; bash -l"

# Custom profile
./ec2client.sh -t Name=dev -s "cd; bash --rcfile ~/.custom_profile"
```

### Multiple Tag Combinations

```bash
# Value with equals sign
./ec2client.sh -t Team=backend-api -t Config=ssl=enabled

# Spaces in values
./ec2client.sh -t Team=backend-api -t Name='Production Web Server'
```

## Using with awsenv

If awsenv wrapper scripts are installed, ec2client works directly:

```bash
ec2client -t Environment=prod
```

To run ec2client inside an awsenv container (for environments without local AWS CLI), install openssh-clients for SSH support:

```bash
# Connect to EC2 via SSM with awsenv
awsenv ec2client -t Environment=staging

# Connect to EC2 via SSH with awsenv
# Note: For SSH, the key must be mounted into the container as shown below.
awsenv -p openssh-clients -m ~/.ssh/key.pem:/keys/key.pem:ro \
  ec2client -t Name=bastion -c ssh -k /keys/key.pem
```

**Note**: SSM connections work without additional packages. SSH connections require the openssh-clients package.
