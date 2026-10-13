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

CONNECT_METHOD="ssm"
SSH_USER="ec2-user"
SSH_KEY_FILE=""
TAG_KEYS=""
TAG_VALUES=""
TAG_COUNT=0
SELECTED_ID=""
SELECTED_IP=""
SSM_COMMAND="sh"
SSM_COMMAND_GIVEN=0
SELECTOR=""

usage() {
  _usage_exit_code="${1:-1}"

  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Optional:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -i INDEX|ID       Select instance by 1-based list index or instance ID
  -c METHOD         Connection method (ssh or ssm, default: ssm)
  -u USER           SSH user (default: ec2-user)
  -k KEYFILE        SSH private key file path
  -s COMMAND        SSM command to execute (default: sh). When stdin is not a
                    terminal, runs COMMAND as root via SSM send-command, prints
                    its output, and exits with its status
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
  $0 -t Environment=prod -t Team=backend
  $0 -t Environment=prod -i i-0123456789abcdef0
  $0 -t Name=bastion -c ssh -k ~/.ssh/mykey.pem
  $0 -t Environment=staging -s "cd; bash -l"
EOF
  exit "$_usage_exit_code"
}

# --- BEGIN SHARED: error_exit ---
error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}
# --- END SHARED: error_exit ---

# --- BEGIN SHARED: trim_whitespace ---
trim_whitespace() {
  printf "%s" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
# --- END SHARED: trim_whitespace ---

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

reject_comma_in_tag_value() {
  _reject_value="$1"
  case "$_reject_value" in
  *,*) error_exit "Invalid tag value '$_reject_value': ',' is not supported (EC2 filters treat it as a value separator)" ;;
  esac
}

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
  while getopts "t:i:c:u:k:s:h" _parse_opt; do
    case "$_parse_opt" in
    t)
      parse_tag_argument "$OPTARG"
      validate_tag_format "$OPTARG" "$PARSED_KEY" "$PARSED_VALUE"
      reject_comma_in_tag_value "$PARSED_VALUE"
      accumulate_tags "$PARSED_KEY" "$PARSED_VALUE"
      ;;
    i)
      [ -n "$OPTARG" ] || error_exit "Selector cannot be empty"
      SELECTOR="$OPTARG"
      ;;
    c) CONNECT_METHOD="$OPTARG" ;;
    u) SSH_USER="$OPTARG" ;;
    k) SSH_KEY_FILE="$OPTARG" ;;
    s)
      SSM_COMMAND="$OPTARG"
      SSM_COMMAND_GIVEN=1
      ;;
    h) usage 0 ;;
    *) usage ;;
    esac
  done

  shift $((OPTIND - 1))
  [ $# -gt 0 ] && error_exit "Unexpected argument: $1"

  return 0
}

validate_connect_method() {
  case "$CONNECT_METHOD" in
  ssh | ssm) ;;
  *) error_exit "Connection method must be: ssh or ssm" ;;
  esac
}

validate_ssh_key_file() {
  [ -n "$SSH_KEY_FILE" ] || return 0
  [ -f "$SSH_KEY_FILE" ] || error_exit "SSH private key file not found: $SSH_KEY_FILE"
  case "$SSH_KEY_FILE" in
  *[\$\`\\\"\'\ ]*) error_exit "SSH key file path contains unsafe characters" ;;
  esac
}

validate_ssh_user() {
  case "$SSH_USER" in
  *[\$\`\\\"\'\;\ ]*) error_exit "SSH user contains unsafe characters" ;;
  "") error_exit "SSH user cannot be empty" ;;
  esac
}

validate_selector() {
  [ -n "$SELECTOR" ] || return 0
  printf "%s" "$SELECTOR" | grep -Eq '^([0-9]+|i-[0-9a-f]+)$' ||
    error_exit "Selector must be a list index or an instance ID (i-...): $SELECTOR"
}

validate_ssm_command() {
  [ "$SSM_COMMAND_GIVEN" -eq 0 ] || [ "$CONNECT_METHOD" = "ssm" ] ||
    error_exit "-s applies only to -c ssm"
}

validate_parameters() {
  validate_selector
  validate_connect_method
  validate_ssm_command
  validate_ssh_key_file
  validate_ssh_user
}

runs_as_command() {
  [ "$SSM_COMMAND_GIVEN" -eq 1 ] && [ ! -t 0 ]
}

check_dependencies() {
  for _check_tool in aws jq; do
    command -v "$_check_tool" >/dev/null 2>&1 || error_exit "'$_check_tool' is required but not found"
  done

  if [ "$CONNECT_METHOD" = "ssm" ] && ! runs_as_command; then
    command -v session-manager-plugin >/dev/null 2>&1 || error_exit "'session-manager-plugin' is required but not found"
  fi

  if [ "$CONNECT_METHOD" = "ssh" ]; then
    command -v ssh >/dev/null 2>&1 || error_exit "'ssh' is required but not found"
  fi

  return 0
}

build_tag_display_message() {
  if [ "$TAG_COUNT" -eq 0 ]; then
    printf "all running EC2 instances"
    return
  fi

  if [ "$TAG_COUNT" -eq 1 ]; then
    get_tag_at_index 1
    printf "EC2 instances with %s=%s" "$TAG_KEY_AT_INDEX" "$TAG_VALUE_AT_INDEX"
    return
  fi

  printf "EC2 instances with %d tag filters" "$TAG_COUNT"
}

normalize_none_fields() {
  awk -F'\t' 'BEGIN { OFS = "\t" }
    { for (i = 1; i <= NF; i++) { if ($i == "None" || $i == "null") $i = "" }; print }'
}

query_instances() {
  set -- "Name=instance-state-name,Values=running"

  _query_i=1
  while [ "$_query_i" -le "$TAG_COUNT" ]; do
    get_tag_at_index "$_query_i"
    set -- "$@" "Name=tag:$TAG_KEY_AT_INDEX,Values=$TAG_VALUE_AT_INDEX"
    _query_i=$((_query_i + 1))
  done

  _query_msg=$(build_tag_display_message)
  printf "Searching for %s...\n" "$_query_msg" >&2

  # shellcheck disable=SC2016
  _query_res=$(AWSENV_TTY=never aws ec2 describe-instances \
    --filters "$@" \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],PublicIpAddress]' \
    --output text) || error_exit "Failed to query EC2 instances"

  printf "%s" "$_query_res" | normalize_none_fields | sort -t"$(printf '\t')" -k2,2
}

parse_instance_list() {
  _parse_inst_list="$1"
  printf "%s\n" "$_parse_inst_list" | awk '{if (NF > 0) print $1}'
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

count_instances() {
  _count_inst_ids="$1"
  count_lines "$_count_inst_ids"
}

display_instance_line() {
  _disp_idx="$1"
  _disp_id="$2"
  _disp_name="$3"
  _disp_ip="$4"

  _disp_display_name="${_disp_name:-$_disp_id}"
  _disp_display_ip="${_disp_ip:-no-public-ip}"
  printf "%d. %s (%s): %s\n" "$_disp_idx" "$_disp_display_name" "$_disp_id" "$_disp_display_ip" >&2
}

display_instances() {
  _disp_inst_list="$1"

  printf "\n" >&2
  _disp_inst_i=1
  printf "%s\n" "$_disp_inst_list" | while IFS="$(printf '\t')" read -r _disp_inst_id _disp_inst_name _disp_inst_ip; do
    if [ -n "$_disp_inst_id" ]; then
      display_instance_line "$_disp_inst_i" "$_disp_inst_id" "$_disp_inst_name" "$_disp_inst_ip"
      _disp_inst_i=$((_disp_inst_i + 1))
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

select_instance() {
  _select_inst_list="$1"
  _select_inst_ids=$(parse_instance_list "$_select_inst_list")
  _select_inst_count=$(count_instances "$_select_inst_ids")

  [ "$_select_inst_count" -eq 0 ] && error_exit "No instances found"

  if [ -n "$SELECTOR" ]; then
    _select_inst_choice=$(resolve_selection "$_select_inst_ids" "$_select_inst_count" "$SELECTOR" "instance")
  elif [ "$_select_inst_count" -eq 1 ]; then
    printf "Connecting to instance...\n" >&2
    _select_inst_choice=1
  else
    display_instances "$_select_inst_list"
    _select_inst_choice=$(read_user_selection "$_select_inst_count" "instance")
  fi

  SELECTED_LINE=$(printf "%s\n" "$_select_inst_list" | sed -n "${_select_inst_choice}p")
  SELECTED_ID=$(printf "%s" "$SELECTED_LINE" | cut -f1)
  SELECTED_IP=$(printf "%s" "$SELECTED_LINE" | cut -f3)
}

connect_ssh() {
  printf "Connecting to %s via SSH...\n" "$SELECTED_ID" >&2
  [ -z "$SELECTED_IP" ] && error_exit "Instance does not have a public IP address for SSH connection"

  if [ -n "$SSH_KEY_FILE" ]; then
    printf "ssh -A -i %s %s@%s\n" "$SSH_KEY_FILE" "$SSH_USER" "$SELECTED_IP" >&2
    exec ssh -A -i "$SSH_KEY_FILE" "$SSH_USER@$SELECTED_IP"
  fi

  printf "ssh -A %s@%s\n" "$SSH_USER" "$SELECTED_IP" >&2
  exec ssh -A "$SSH_USER@$SELECTED_IP"
}

build_ssm_parameters() {
  jq -nc --arg cmd "$SSM_COMMAND" '{"command":[$cmd]}'
}

connect_ssm() {
  printf "Connecting to %s via SSM...\n" "$SELECTED_ID" >&2
  _connect_ssm_cmd_json=$(build_ssm_parameters)
  AWSENV_TTY=always exec aws ssm start-session \
    --target "$SELECTED_ID" \
    --document-name "AWS-StartInteractiveCommand" \
    --parameters "$_connect_ssm_cmd_json"
}

report_command_failure() {
  _rcf_id="$1"
  _rcf_status="$2"

  case "$_rcf_status" in
  Pending | InProgress | Delayed)
    error_exit "Command $_rcf_id still $_rcf_status after waiting; check: aws ssm get-command-invocation --command-id $_rcf_id --instance-id $SELECTED_ID"
    ;;
  esac
  error_exit "Command $_rcf_id ended with status $_rcf_status"
}

run_ssm_command() {
  printf "Running command on %s via SSM...\n" "$SELECTED_ID" >&2
  _rsc_parameters=$(jq -nc --arg cmd "$SSM_COMMAND" '{"commands":[$cmd]}')

  _rsc_command_id=$(AWSENV_TTY=never aws ssm send-command \
    --instance-ids "$SELECTED_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters "$_rsc_parameters" \
    --query "Command.CommandId" \
    --output text) || error_exit "Failed to send command to $SELECTED_ID"

  # Exits non-zero for any terminal status other than Success; the invocation
  # fetched below carries the real status and output.
  AWSENV_TTY=never aws ssm wait command-executed \
    --command-id "$_rsc_command_id" \
    --instance-id "$SELECTED_ID" || true

  _rsc_result=$(AWSENV_TTY=never aws ssm get-command-invocation \
    --command-id "$_rsc_command_id" \
    --instance-id "$SELECTED_ID" \
    --output json) || error_exit "Failed to fetch result of command $_rsc_command_id"

  printf "%s" "$_rsc_result" | jq -j '.StandardOutputContent'
  printf "%s" "$_rsc_result" | jq -j '.StandardErrorContent' >&2

  _rsc_status=$(printf "%s" "$_rsc_result" | jq -r '.Status')
  _rsc_code=$(printf "%s" "$_rsc_result" | jq -r '.ResponseCode // -1')
  if [ "$_rsc_status" != "Success" ] && [ "$_rsc_code" -le 0 ]; then
    report_command_failure "$_rsc_command_id" "$_rsc_status"
  fi
  exit "$_rsc_code"
}

connect() {
  case "$CONNECT_METHOD" in
  ssh) connect_ssh ;;
  ssm) connect_ssm ;;
  *) error_exit "Connection method must be: ssh or ssm" ;;
  esac
}

main() {
  parse_options "$@"
  validate_parameters
  check_dependencies

  _main_inst_data=$(query_instances)
  select_instance "$_main_inst_data"
  if runs_as_command; then
    run_ssm_command
  fi
  connect
}

main "$@"
