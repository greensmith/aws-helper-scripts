#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ec2-start-session.sh
#
# A modern EC2 SSM session helper using fzf for interactive selection.
# Presents running instances with Name tags, instance details, and a preview
# pane, then starts an SSM session on the selected instance.
#
# Dependencies: aws (v2), fzf, jq
###############################################################################

readonly VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Colours for fzf entries
readonly C_BLUE='\033[1;34m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[1;36m'
readonly C_RESET='\033[0m'

# Temp directory for caching API responses
TMPDIR_CACHE=""

cleanup() {
  [[ -n "${TMPDIR_CACHE}" && -d "${TMPDIR_CACHE}" ]] && rm -rf "${TMPDIR_CACHE}"
}
trap cleanup EXIT

###############################################################################
# Help
###############################################################################
_help() {
  cat << EOF
Usage: ${SCRIPT_NAME} [-h] [-p profile] [-r region]

A modern helper script to select and start SSM sessions on EC2 instances.

Uses fzf for interactive fuzzy selection of:
  - AWS profile (from ~/.aws/config) — skipped if --profile is provided
  - EC2 instance (with metadata preview)

Options:
  -h, --help       Print this help and exit
  -p, --profile    AWS profile to use (bypasses fzf profile selection)
  -r, --region     AWS region override (otherwise uses profile default)
  -v, --version    Print version and exit

Requirements:
  - aws CLI v2
  - fzf (https://github.com/junegunn/fzf)
  - jq (https://stedolan.github.io/jq/)
  - SSM Agent running on target instances
EOF
  exit 0
}

###############################################################################
# Dependency checks
###############################################################################
_check_deps() {
  local missing=()
  for cmd in aws fzf jq; do
    if ! command -v "${cmd}" &>/dev/null; then
      missing+=("${cmd}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required dependencies: ${missing[*]}" >&2
    echo "Please install them before running this script." >&2
    exit 1
  fi
}

###############################################################################
# Argument parsing
###############################################################################
REGION_FLAG=""
PROFILE_FLAG=""

_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -h|--help) _help ;;
      -v|--version) echo "${SCRIPT_NAME} v${VERSION}"; exit 0 ;;
      -p|--profile)
        PROFILE_FLAG="--profile ${2-}"
        shift
        ;;
      -r|--region)
        REGION_FLAG="--region ${2-}"
        shift
        ;;
      -*) echo "Unknown option: ${1}" >&2; exit 1 ;;
      *) break ;;
    esac
    shift
  done
}

###############################################################################
# Profile picker — parse ~/.aws/config
###############################################################################
_pick_profile() {
  local config_file="${AWS_CONFIG_FILE:-$HOME/.aws/config}"

  if [[ ! -f "${config_file}" ]]; then
    echo "Error: AWS config file not found at ${config_file}" >&2
    exit 1
  fi

  local profiles
  profiles=$(grep -oP '(?<=\[profile )[^\]]+(?=\])' "${config_file}" | sort)

  if [[ -z "${profiles}" ]]; then
    echo "Error: No profiles found in ${config_file}" >&2
    exit 1
  fi

  local selected
  selected=$(echo "${profiles}" | fzf --prompt="AWS Profile > " --height=40% --border --header="Select an AWS profile")

  if [[ -z "${selected}" ]]; then
    echo "Cancelled." >&2
    exit 1
  fi

  echo "${selected}"
}

###############################################################################
# Fetch EC2 instances
###############################################################################
_fetch_instances() {
  local profile_flag="$1"
  local region_flag="$2"
  local aws_cmd="aws ${profile_flag} ${region_flag}"

  echo "Fetching running EC2 instances..." >&2

  local instances_json
  if ! instances_json=$(eval ${aws_cmd} ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --output json 2>&1); then
    echo "Error fetching instances:" >&2
    echo "${instances_json}" >&2
    exit 1
  fi

  echo "${instances_json}" > "${TMPDIR_CACHE}/instances.json"

  # Build entries TSV: instance_id \t name \t instance_type \t az \t private_ip \t public_ip \t launch_time \t state
  local entries_file="${TMPDIR_CACHE}/entries.tsv"
  echo "${instances_json}" | jq -r '
    .Reservations[].Instances[] |
    .InstanceId as $id |
    (.Tags // [] | map(select(.Key == "Name")) | if length > 0 then .[0].Value else "N/A" end) as $name |
    .InstanceType as $type |
    .Placement.AvailabilityZone as $az |
    (.PrivateIpAddress // "N/A") as $priv_ip |
    (.PublicIpAddress // "N/A") as $pub_ip |
    (.LaunchTime // "N/A") as $launch |
    .State.Name as $state |
    [$id, $name, $type, $az, $priv_ip, $pub_ip, $launch, $state] |
    @tsv
  ' > "${entries_file}" 2>/dev/null || true

  if [[ ! -s "${entries_file}" ]]; then
    echo "No running EC2 instances found." >&2
    exit 1
  fi
}

###############################################################################
# Pick instance with fzf + preview pane
###############################################################################
_pick_instance() {
  local entries_file="${TMPDIR_CACHE}/entries.tsv"

  # Build display: line_num \t name (instance_id) \t type \t az
  local display_file="${TMPDIR_CACHE}/display.txt"
  awk -F'\t' '{printf "%d\t\033[1;36m%-35s\033[0m  \033[1;33m%-20s\033[0m  \033[1;32m%-12s\033[0m  \033[1;34m%-15s\033[0m\n", NR, substr($2,1,35), $1, $3, $4}' \
    "${entries_file}" > "${display_file}"

  local header
  header=$(printf "%-35s  %-20s  %-12s  %-15s" "NAME" "INSTANCE ID" "TYPE" "AZ")

  # Preview script
  local preview_script="${TMPDIR_CACHE}/preview.sh"
  cat > "${preview_script}" << PREVIEW
#!/usr/bin/env bash
line_num=\$(echo "\$1" | cut -f1)
entries_file="${entries_file}"
line=\$(sed -n "\${line_num}p" "\${entries_file}")
IFS=\$'\t' read -r instance_id name instance_type az private_ip public_ip launch_time state <<< "\${line}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              Instance Details                        ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║"
printf "║  %-14s %s\n" "Name:" "\${name}"
printf "║  %-14s %s\n" "Instance ID:" "\${instance_id}"
printf "║  %-14s %s\n" "Type:" "\${instance_type}"
printf "║  %-14s %s\n" "State:" "\${state}"
echo "║"
echo "║  ── Network ──"
printf "║  %-14s %s\n" "AZ:" "\${az}"
printf "║  %-14s %s\n" "Private IP:" "\${private_ip}"
printf "║  %-14s %s\n" "Public IP:" "\${public_ip}"
echo "║"
echo "║  ── Lifecycle ──"
printf "║  %-14s %s\n" "Launched:" "\${launch_time}"
echo "║"
echo "╚══════════════════════════════════════════════════════╝"
PREVIEW
  chmod +x "${preview_script}"

  local selected_line
  selected_line=$(cat "${display_file}" | \
    fzf --ansi \
        --prompt="Select instance > " \
        --header="${header}" \
        --border \
        --height=80% \
        --preview="${preview_script} {}" \
        --preview-window=right:45%:wrap \
        --with-nth=2.. \
        --delimiter=$'\t')

  if [[ -z "${selected_line}" ]]; then
    echo "Cancelled." >&2
    exit 1
  fi

  local line_num
  line_num=$(echo "${selected_line}" | cut -f1)

  sed -n "${line_num}p" "${entries_file}"
}

###############################################################################
# Main
###############################################################################
main() {
  _check_deps
  _parse_args "$@"

  # Create temp cache directory
  TMPDIR_CACHE=$(mktemp -d)

  # Step 1: Pick AWS profile (or use --profile flag)
  local profile_flag
  if [[ -n "${PROFILE_FLAG}" ]]; then
    profile_flag="${PROFILE_FLAG}"
    echo "Using profile: ${PROFILE_FLAG#--profile }"
  else
    echo "Select AWS profile..."
    local profile
    profile=$(_pick_profile)
    profile_flag="--profile ${profile}"
    echo "Using profile: ${profile}"
  fi

  # Step 2: Fetch running EC2 instances
  _fetch_instances "${profile_flag}" "${REGION_FLAG}"

  # Step 3: Pick instance
  local selected_entry
  selected_entry=$(_pick_instance)

  IFS=$'\t' read -r instance_id name instance_type az private_ip public_ip launch_time state <<< "${selected_entry}"

  echo ""
  echo "Selected:"
  echo "  Name:        ${name}"
  echo "  Instance ID: ${instance_id}"
  echo "  Type:        ${instance_type}"
  echo "  AZ:          ${az}"
  echo "  Private IP:  ${private_ip}"
  echo ""

  # Step 4: Start SSM session
  echo "Starting SSM session..."
  echo "  aws ${profile_flag} ${REGION_FLAG} ssm start-session --target ${instance_id}"
  echo ""

  eval aws "${profile_flag}" ${REGION_FLAG} ssm start-session \
    --target "${instance_id}"
}

main "$@"