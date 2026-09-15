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

BASE_IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"
readonly BASE_IMAGE
IMAGE_PREFIX="awsenv-cli"
readonly IMAGE_PREFIX
MOUNT_SEPARATOR="$(printf '\036')"
readonly MOUNT_SEPARATOR

usage() {
  _usage_exit_code="${1:-1}"

  cat >&2 <<EOF
Usage: $0 [OPTIONS] <command> [args...]

Optional:
  -p PACKAGE        Additional package to install (can be specified multiple times)
  -f FILE           File containing packages to install (one per line)
  -m MOUNT          Mount path as <local_path>:<docker_dir>[:(ro|rw)]
                    <local_path> may be a directory or a file
                    Default is read-write (rw) if not specified
                    Can be specified multiple times
  -h                Show this help message

Environment Variables:
  AWSENV_TTY            Control TTY allocation (always|never|auto, default: auto)
  AWSENV_AWS_DIR_MODE   Control AWS directory mount (ro|rw|auto, default: auto)
                        'auto' uses read-write for configure/sso commands
  AWSENV_PWD_MODE       Control current directory mount (rw|ro|off, default: rw)

Examples:
  $0 aws s3 ls
  $0 -p vim ./my-script.sh
  $0 -f packages.txt ./rdsclient.sh -t Environment -v prod
  $0 -m \$(pwd)/logs:/logs:ro -m /data:/mnt/data:rw ./process.sh
  AWSENV_TTY=never $0 aws ec2 describe-instances
  $0 aws configure sso
  $0 aws configure sso --use-device-code
  AWSENV_AWS_DIR_MODE=rw $0 aws s3 ls
  AWSENV_PWD_MODE=off $0 aws --version
EOF
  exit "$_usage_exit_code"
}

# --- BEGIN SHARED: error_exit ---
error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}
# --- END SHARED: error_exit ---

is_valid_identifier() {
  case "$1" in
  *[!A-Za-z0-9_]* | [0-9]* | "") return 1 ;;
  *) return 0 ;;
  esac
}

validate_command_name() {
  case "$1" in
  *[\'\"\`\$\&\|\;\<\>\(\)\{\}\[\]]*) error_exit "Command name contains invalid characters" ;;
  "") error_exit "Command name cannot be empty" ;;
  esac
}

validate_docker_path() {
  _vdp_path="$1"
  case "$_vdp_path" in
  *..*) error_exit "Docker path '$_vdp_path' cannot contain '..'" ;;
  esac
}

validate_mount_format() {
  _vmf_mount="$1"

  _vmf_old_ifs="$IFS"
  IFS=":"

  # shellcheck disable=SC2086
  set -- $_vmf_mount
  IFS="$_vmf_old_ifs"

  _vmf_count=$#
  [ "$_vmf_count" -lt 2 ] && error_exit "Invalid mount format '$_vmf_mount'"
  [ "$_vmf_count" -gt 3 ] && error_exit "Invalid mount format '$_vmf_mount'"

  _vmf_local_path="$1"
  _vmf_docker_dir="$2"

  if [ "$_vmf_count" -eq 3 ]; then
    _vmf_mode="$3"
    case "$_vmf_mode" in
    ro | rw) ;;
    *) error_exit "Invalid mount mode '$_vmf_mode'. Expected 'ro' or 'rw'" ;;
    esac
  fi

  [ ! -e "$_vmf_local_path" ] && error_exit "Mount path '$_vmf_local_path' does not exist"
  [ ! -r "$_vmf_local_path" ] && error_exit "Mount path '$_vmf_local_path' is not readable"
  validate_docker_path "$_vmf_docker_dir"

  return 0
}

validate_mounts() {
  [ -z "$MOUNTS" ] && return 0

  _vm_old_ifs="$IFS"
  IFS="$MOUNT_SEPARATOR"

  # shellcheck disable=SC2086
  set -- $MOUNTS
  IFS="$_vm_old_ifs"

  for _vm_mount in "$@"; do
    [ -n "$_vm_mount" ] && validate_mount_format "$_vm_mount"
  done
}

validate_aws_dir_mode() {
  _vadm_mode="${AWSENV_AWS_DIR_MODE:-auto}"
  case "$_vadm_mode" in
  auto | ro | rw) ;;
  *) error_exit "Invalid AWSENV_AWS_DIR_MODE '$_vadm_mode'. Expected 'auto', 'ro', or 'rw'" ;;
  esac
}

validate_pwd_mode() {
  _vpm_mode="${AWSENV_PWD_MODE:-rw}"
  case "$_vpm_mode" in
  rw | ro | off) ;;
  *) error_exit "Invalid AWSENV_PWD_MODE '$_vpm_mode'. Expected 'rw', 'ro', or 'off'" ;;
  esac
}

validate_tty_mode() {
  _vtm_mode="${AWSENV_TTY:-auto}"
  case "$_vtm_mode" in
  always | never | auto) ;;
  *) error_exit "Invalid AWSENV_TTY '$_vtm_mode'. Expected 'always', 'never', or 'auto'" ;;
  esac
}

validate_parameters() {
  validate_command_name "$CMD"
  validate_mounts
  validate_aws_dir_mode
  validate_pwd_mode
  validate_tty_mode
}

parse_arguments() {
  PACKAGES=""
  PACKAGE_FILE=""
  MOUNTS=""

  while getopts "p:f:m:h" _parse_opt; do
    case "$_parse_opt" in
    p) PACKAGES="$PACKAGES $OPTARG" ;;
    f) PACKAGE_FILE="$OPTARG" ;;
    m)
      if [ -z "$MOUNTS" ]; then
        MOUNTS="$OPTARG"
      else
        MOUNTS="$MOUNTS${MOUNT_SEPARATOR}$OPTARG"
      fi
      ;;
    h) usage 0 ;;
    *) usage ;;
    esac
  done

  shift $((OPTIND - 1))
  if [ $# -eq 0 ]; then
    error_exit "No command specified"
  fi

  CMD="$1"
  shift

  CMD_ARGS_START=$((OPTIND + 1))
}

read_packages_from_file() {
  _read_file="$1"
  [ ! -f "$_read_file" ] && error_exit "Package file '$_read_file' does not exist"
  [ ! -r "$_read_file" ] && error_exit "Package file '$_read_file' is not readable"

  while IFS= read -r _read_line || [ -n "$_read_line" ]; do
    _read_line=$(printf "%s" "$_read_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$_read_line" in
    '' | '#'*) continue ;;
    *) printf "%s " "$_read_line" ;;
    esac
  done <"$_read_file"
}

merge_and_sort_packages() {
  _merge_all="$1"
  [ -z "$_merge_all" ] && return
  printf "%s" "$_merge_all" | tr ' ' '\n' | grep -v '^[[:space:]]*$' | sort -u | tr '\n' ' '
}

hash_packages() {
  _hash_pkgs="$1"
  if command -v cksum >/dev/null 2>&1; then
    printf "%s" "$_hash_pkgs" | cksum | awk '{print $1}'
  elif command -v sum >/dev/null 2>&1; then
    printf "%s" "$_hash_pkgs" | sum | awk '{print $1}'
  else
    printf "%s" "$_hash_pkgs" | wc -c
  fi
}

compute_image_tag() {
  _compute_pkgs="$1"
  if [ -z "$_compute_pkgs" ]; then
    printf "base"
    return
  fi

  hash_packages "$_compute_pkgs"
}

generate_image_name() {
  printf "%s:%s" "$IMAGE_PREFIX" "$(compute_image_tag "$1")"
}

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

create_dockerfile() {
  _dockerfile_pkgs="$1"
  _dockerfile_cmd="yum install -y unzip"
  [ -n "$_dockerfile_pkgs" ] && _dockerfile_cmd="$_dockerfile_cmd $_dockerfile_pkgs"

  # session-manager-plugin ships separate x86_64 and arm64 RPMs; detect the
  # image's own architecture at build time rather than the host's, since a
  # buildx --platform build can target an architecture the host doesn't have.
  cat <<EOF
FROM $BASE_IMAGE
RUN $_dockerfile_cmd && \\
    case "\$(uname -m)" in \\
    aarch64 | arm64) _smp_arch=linux_arm64 ;; \\
    *) _smp_arch=linux_64bit ;; \\
    esac && \\
    curl -sSL -o /tmp/session-manager-plugin.rpm \\
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/\${_smp_arch}/session-manager-plugin.rpm" && \\
    yum install -y /tmp/session-manager-plugin.rpm && \\
    rm -f /tmp/session-manager-plugin.rpm && \\
    yum clean all
EOF
}

build_custom_image() {
  _build_pkgs="$1"

  image_exists "$IMAGE" && return 0

  echo "Building custom image: $IMAGE" >&2
  [ -n "$_build_pkgs" ] && echo "Installing packages: $_build_pkgs" >&2
  create_dockerfile "$_build_pkgs" | docker build -t "$IMAGE" - >&2
}

determine_image() {
  _det_file_pkgs=""
  [ -n "$PACKAGE_FILE" ] && _det_file_pkgs=$(read_packages_from_file "$PACKAGE_FILE")
  _det_all_pkgs="$PACKAGES $_det_file_pkgs"
  _det_sorted_pkgs=$(merge_and_sort_packages "$_det_all_pkgs")
  _det_sorted_pkgs=$(printf "%s" "$_det_sorted_pkgs" | sed 's/[[:space:]]*$//')
  IMAGE=$(generate_image_name "$_det_sorted_pkgs")
  build_custom_image "$_det_sorted_pkgs"
}

is_aws_cli_builtin() {
  test "$1" = "aws" || test "$1" = "aws_completer" || test "$1" = "session-manager-plugin"
}

try_readlink_f() {
  _try_target="$1"
  command -v readlink >/dev/null 2>&1 || return 1
  readlink -f "$_try_target" 2>/dev/null
}

resolve_link_target() {
  _link_curr="$1"
  _link_target="$2"

  case "$_link_target" in
  /*) printf "%s" "$_link_target" ;;
  *) printf "%s/%s" "$(dirname "$_link_curr")" "$_link_target" ;;
  esac
}

canonicalize_path() {
  _canon_path="$1"
  [ ! -e "$_canon_path" ] && return 1

  cd -P "$(dirname "$_canon_path")" >/dev/null 2>&1 || return 1
  printf "%s/%s" "$(pwd -P)" "$(basename "$_canon_path")"
  cd - >/dev/null 2>&1 || true
}

resolve_symlink_manually() {
  _rsm_curr="$1"
  _rsm_depth=40

  while [ "$_rsm_depth" -gt 0 ]; do
    if [ ! -L "$_rsm_curr" ]; then
      canonicalize_path "$_rsm_curr"
      return $?
    fi

    _rsm_target=$(readlink "$_rsm_curr")
    _rsm_curr=$(resolve_link_target "$_rsm_curr" "$_rsm_target")
    _rsm_depth=$((_rsm_depth - 1))
  done

  return 1
}

resolve_symlink() {
  _res_target="$1"
  if _res_resolved=$(try_readlink_f "$_res_target"); then
    printf "%s" "$_res_resolved"
    return 0
  fi

  resolve_symlink_manually "$_res_target"
}

find_command_path() {
  [ -d "$CMD" ] && return 1

  if [ -f "./$CMD" ] && [ -x "./$CMD" ]; then
    printf "%s" "$(pwd)/$CMD"
    return 0
  fi

  _find_cmd_loc=$(command -v "$CMD" 2>/dev/null || true)
  if [ -n "$_find_cmd_loc" ]; then
    printf "%s" "$_find_cmd_loc"
    return 0
  fi

  return 1
}

resolve_command_location() {
  CMD_PATH=""
  CMD_MOUNT_DIR=""

  if is_aws_cli_builtin "$CMD"; then
    CMD_PATH="$CMD"
    return 0
  fi

  _rcl_found=$(find_command_path) || error_exit "Command '$CMD' does not exist or is not an executable file"
  _rcl_resolved=$(resolve_symlink "$_rcl_found") || error_exit "Failed to resolve symlink for '$_rcl_found'"
  CMD_PATH="$_rcl_resolved"
  [ -e "$CMD_PATH" ] && CMD_MOUNT_DIR="$(dirname "$CMD_PATH")"
}

GLOBAL_OPTS_WITH_VALUE=" --profile --region --output --endpoint-url --ca-bundle --cli-read-timeout --cli-connect-timeout --color --query --cli-binary-format "
readonly GLOBAL_OPTS_WITH_VALUE

get_positional_args() {
  shift $((CMD_ARGS_START - 1))

  FIRST_POS=""
  SECOND_POS=""
  _pos_skip_next=0

  for _pos_arg in "$@"; do
    if [ "$_pos_skip_next" -eq 1 ]; then
      _pos_skip_next=0
      continue
    fi

    case "$_pos_arg" in
    --*=*) continue ;;
    --*)
      case "$GLOBAL_OPTS_WITH_VALUE" in
      *" $_pos_arg "*) _pos_skip_next=1 ;;
      esac
      continue
      ;;
    -*) continue ;;
    *)
      if [ -z "$FIRST_POS" ]; then
        FIRST_POS="$_pos_arg"
      elif [ -z "$SECOND_POS" ]; then
        SECOND_POS="$_pos_arg"
        break
      fi
      ;;
    esac
  done
}

has_device_code_flag() {
  shift $((CMD_ARGS_START - 1))
  for _hdc_arg in "$@"; do
    case "$_hdc_arg" in
    --use-device-code) return 0 ;;
    esac
  done
  return 1
}

profile_needs_write_access() {
  [ "$CMD" != "aws" ] && return 1
  [ ! -d "$HOME/.aws" ] && return 1

  _pnw_profile=""

  shift $((CMD_ARGS_START - 1))
  while [ $# -gt 0 ]; do
    case "$1" in
    --profile)
      shift
      _pnw_profile="${1:-}"
      break
      ;;
    --profile=*)
      _pnw_profile="${1#--profile=}"
      break
      ;;
    esac
    shift
  done

  [ -z "$_pnw_profile" ] && _pnw_profile="${AWS_PROFILE:-default}"

  _pnw_config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  [ ! -f "$_pnw_config" ] && return 1

  if grep -q "^\[profile $_pnw_profile\]" "$_pnw_config" 2>/dev/null; then
    sed -n "/^\[profile $_pnw_profile\]/,/^\[/p" "$_pnw_config" | grep -Eq "^(sso_|role_arn)" && return 0
  elif grep -q "^\[$_pnw_profile\]" "$_pnw_config" 2>/dev/null; then
    sed -n "/^\[$_pnw_profile\]/,/^\[/p" "$_pnw_config" | grep -Eq "^(sso_|role_arn)" && return 0
  fi

  return 1
}

needs_aws_dir_writable() {
  [ "$CMD" != "aws" ] && return 1

  get_positional_args "$@"

  case "$FIRST_POS" in
  configure)
    case "$SECOND_POS" in
    "" | set | sso | sso-session | import) return 0 ;;
    esac
    ;;
  sso)
    case "$SECOND_POS" in
    login | logout) return 0 ;;
    esac
    ;;
  esac

  profile_needs_write_access "$@" && return 0

  return 1
}

needs_host_network() {
  [ "$CMD" != "aws" ] && return 1

  has_device_code_flag "$@" && return 1

  get_positional_args "$@"

  case "$FIRST_POS" in
  configure)
    test "$SECOND_POS" = "sso" && return 0
    ;;
  sso)
    test "$SECOND_POS" = "login" && return 0
    ;;
  esac

  return 1
}

should_allocate_tty() {
  case "${AWSENV_TTY:-auto}" in
  always) return 0 ;;
  never) return 1 ;;
  *) [ -t 0 ] ;;
  esac
}

determine_docker_tty_flags() {
  if should_allocate_tty; then
    printf "%s" "-it"
  else
    printf "%s" "-i"
  fi
}

determine_aws_dir_mode() {
  _dadm_mode="${AWSENV_AWS_DIR_MODE:-auto}"

  case "$_dadm_mode" in
  ro | rw)
    printf "%s" "$_dadm_mode"
    return 0
    ;;
  esac

  if needs_aws_dir_writable "$@"; then
    printf "rw"
  else
    printf "ro"
  fi
}

determine_pwd_mode() {
  printf "%s" "${AWSENV_PWD_MODE:-rw}"
}

aws_credentials_mount_value() {
  _acmv_mode="$1"
  [ -d "$HOME/.aws" ] && printf "%s:/root/.aws:%s" "$HOME/.aws" "$_acmv_mode"
  return 0
}

count_mounts() {
  if [ -z "$MOUNTS" ]; then
    printf "0"
    return
  fi

  printf "%s" "$MOUNTS" | tr "$MOUNT_SEPARATOR" '\n' | grep -c .
}

get_mount_at_index() {
  _gmai_idx="$1"
  printf "%s" "$MOUNTS" | tr "$MOUNT_SEPARATOR" '\n' | sed -n "${_gmai_idx}p"
}

cmd_mount_shadowed_by_pwd() {
  _cmsp_pwd_mode="$1"

  [ -z "$CMD_MOUNT_DIR" ] && return 1
  [ "$_cmsp_pwd_mode" = "off" ] && return 1

  [ "$CMD_MOUNT_DIR" = "$(pwd)" ] && return 0

  if [ "$_cmsp_pwd_mode" = "rw" ]; then
    case "$CMD_MOUNT_DIR" in
    "$(pwd)"/*) return 0 ;;
    esac
  fi

  return 1
}

check_dependencies() {
  command -v docker >/dev/null 2>&1 || error_exit "docker is required but not found"
}

run_container() {
  _rc_aws_dir_mode=$(determine_aws_dir_mode "$@")
  _rc_pwd_mode=$(determine_pwd_mode)
  _rc_tty_flags=$(determine_docker_tty_flags)

  _rc_host_network=0
  needs_host_network "$@" && _rc_host_network=1

  _rc_skip_cmd_mount=0
  cmd_mount_shadowed_by_pwd "$_rc_pwd_mode" && _rc_skip_cmd_mount=1

  shift $((CMD_ARGS_START - 1))

  set -- "$IMAGE" "$CMD_PATH" "$@"
  set -- -w "$(pwd)" "$@"

  if [ "$_rc_pwd_mode" != "off" ]; then
    set -- -v "$(pwd):$(pwd):$_rc_pwd_mode" "$@"
  fi

  if [ "$_rc_skip_cmd_mount" -eq 0 ] && [ -n "$CMD_MOUNT_DIR" ]; then
    set -- -v "$CMD_MOUNT_DIR:$CMD_MOUNT_DIR:ro" "$@"
  fi

  _rc_mount_count=$(count_mounts)
  _rc_i=1
  while [ "$_rc_i" -le "$_rc_mount_count" ]; do
    _rc_mount=$(get_mount_at_index "$_rc_i")
    [ -n "$_rc_mount" ] && set -- -v "$_rc_mount" "$@"
    _rc_i=$((_rc_i + 1))
  done

  _rc_aws_mount=$(aws_credentials_mount_value "$_rc_aws_dir_mode")
  [ -n "$_rc_aws_mount" ] && set -- -v "$_rc_aws_mount" "$@"

  [ "$_rc_host_network" -eq 1 ] && set -- --network host "$@"

  for _rc_var in $(printenv | grep '^AWS_' | cut -d= -f1); do
    is_valid_identifier "$_rc_var" || continue
    _rc_val=$(printenv "$_rc_var" 2>/dev/null || true)
    [ -n "$_rc_val" ] && set -- -e "$_rc_var" "$@"
  done

  [ -n "${TERM:-}" ] && set -- -e TERM "$@"
  [ -n "${COLUMNS:-}" ] && set -- -e COLUMNS "$@"
  [ -n "${LINES:-}" ] && set -- -e LINES "$@"
  [ -n "${COLORTERM:-}" ] && set -- -e COLORTERM "$@"
  [ -n "${PAGER:-}" ] && set -- -e PAGER "$@"
  [ -n "${LANG:-}" ] && set -- -e LANG "$@"

  for _rc_var in $(printenv | grep '^LC_' | cut -d= -f1); do
    is_valid_identifier "$_rc_var" || continue
    set -- -e "$_rc_var" "$@"
  done

  set -- "$_rc_tty_flags" --rm --entrypoint= "$@"

  exec docker run "$@"
}

main() {
  parse_arguments "$@"
  validate_parameters
  check_dependencies
  determine_image
  resolve_command_location
  run_container "$@"
}

main "$@"
