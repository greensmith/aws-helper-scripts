#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ecs-exec-helper.sh
#
# A modern ECS exec helper using fzf for interactive selection.
# Presents a single hierarchical view of clusters/services/tasks/containers
# with Name tags, colours, and a preview pane.
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

A modern helper script to select and execute commands on ECS Fargate containers.

Uses fzf for interactive fuzzy selection of:
  - AWS profile (from ~/.aws/config) — skipped if --profile is provided
  - Cluster / Service / Task / Container (hierarchical view)
  - Command to execute

Options:
  -h, --help       Print this help and exit
  -p, --profile    AWS profile to use (bypasses fzf profile selection)
  -r, --region     AWS region override (otherwise uses profile default)
  -v, --version    Print version and exit

Requirements:
  - aws CLI v2
  - fzf (https://github.com/junegunn/fzf)
  - jq (https://stedolan.github.io/jq/)
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
# Fetch ECS data and build hierarchy
###############################################################################
_fetch_ecs_data() {
  local profile_flag="$1"
  local region_flag="$2"
  local aws_cmd="aws ${profile_flag} ${region_flag}"

  echo "Fetching ECS clusters..." >&2

  # Get clusters
  local clusters_json
  clusters_json=$(eval ${aws_cmd} ecs list-clusters --output json)
  local cluster_arns
  cluster_arns=$(echo "${clusters_json}" | jq -r '.clusterArns[]' 2>/dev/null || true)

  if [[ -z "${cluster_arns}" ]]; then
    echo "No ECS clusters found." >&2
    exit 1
  fi

  # Describe clusters with tags to get Name tag
  local clusters_detail
  clusters_detail=$(eval ${aws_cmd} ecs describe-clusters \
    --clusters $(echo "${cluster_arns}" | tr '\n' ' ') \
    --include TAGS \
    --output json)
  echo "${clusters_detail}" > "${TMPDIR_CACHE}/clusters.json"

  # Build the hierarchical entries
  # TSV columns: container_name | task_display | service_display | cluster_display | cluster_logical | service_logical | task_id | task_arn | status | started | image | health
  local entries_file="${TMPDIR_CACHE}/entries.tsv"
  > "${entries_file}"

  # Build cluster name lookup (Name tag -> logical name fallback)
  local cluster_count
  cluster_count=$(echo "${clusters_detail}" | jq '.clusters | length')

  declare -A cluster_display_map
  for i in $(seq 0 $((cluster_count - 1))); do
    local c_logical c_display
    c_logical=$(echo "${clusters_detail}" | jq -r ".clusters[${i}].clusterName")
    c_display=$(echo "${clusters_detail}" | jq -r "
      .clusters[${i}].tags // [] |
      map(select(.key == \"Name\")) |
      if length > 0 then .[0].value else \"${c_logical}\" end
    ")
    cluster_display_map["${c_logical}"]="${c_display}"
  done

  local cluster_names
  cluster_names=$(echo "${clusters_detail}" | jq -r '.clusters[].clusterName')

  while IFS= read -r cluster_name; do
    [[ -z "${cluster_name}" ]] && continue
    local cluster_display="${cluster_display_map[${cluster_name}]:-${cluster_name}}"
    echo "  Fetching services for cluster: ${cluster_display}..." >&2

    # List services
    local services_json
    services_json=$(eval ${aws_cmd} ecs list-services --cluster "${cluster_name}" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    local service_arns
    service_arns=$(echo "${services_json}" | jq -r '.serviceArns[]' 2>/dev/null || true)

    if [[ -z "${service_arns}" ]]; then
      continue
    fi

    # Describe services with tags for Name tag
    local services_detail
    services_detail=$(eval ${aws_cmd} ecs describe-services \
      --cluster "${cluster_name}" \
      --services $(echo "${service_arns}" | tr '\n' ' ') \
      --include TAGS \
      --output json 2>/dev/null || echo '{"services":[]}')
    echo "${services_detail}" > "${TMPDIR_CACHE}/services_${cluster_name}.json"

    # Build service display name lookup
    local svc_count
    svc_count=$(echo "${services_detail}" | jq '.services | length')

    declare -A service_display_map
    for i in $(seq 0 $((svc_count - 1))); do
      local s_logical s_display
      s_logical=$(echo "${services_detail}" | jq -r ".services[${i}].serviceName")
      s_display=$(echo "${services_detail}" | jq -r "
        .services[${i}].tags // [] |
        map(select(.key == \"Name\")) |
        if length > 0 then .[0].value else \"${s_logical}\" end
      ")
      service_display_map["${s_logical}"]="${s_display}"
    done

    local service_names
    service_names=$(echo "${services_detail}" | jq -r '.services[].serviceName')

    while IFS= read -r service_name; do
      [[ -z "${service_name}" ]] && continue
      local service_display="${service_display_map[${service_name}]:-${service_name}}"

      # List tasks for this service
      local tasks_json
      tasks_json=$(eval ${aws_cmd} ecs list-tasks \
        --cluster "${cluster_name}" \
        --service-name "${service_name}" \
        --output json 2>/dev/null || echo '{"taskArns":[]}')
      local task_arns
      task_arns=$(echo "${tasks_json}" | jq -r '.taskArns[]' 2>/dev/null || true)

      if [[ -z "${task_arns}" ]]; then
        continue
      fi

      # Describe tasks for details
      local tasks_detail
      tasks_detail=$(eval ${aws_cmd} ecs describe-tasks \
        --cluster "${cluster_name}" \
        --tasks $(echo "${task_arns}" | tr '\n' ' ') \
        --output json 2>/dev/null || echo '{"tasks":[]}')
      echo "${tasks_detail}" > "${TMPDIR_CACHE}/tasks_${cluster_name}_${service_name}.json"

      # Extract task/container combos with task definition family:revision as task display name
      echo "${tasks_detail}" | jq -r \
        --arg cluster_display "${cluster_display}" \
        --arg cluster_logical "${cluster_name}" \
        --arg service_display "${service_display}" \
        --arg service_logical "${service_name}" '
        .tasks[] |
        .taskArn as $task_arn |
        (.taskArn | split("/") | last) as $task_id |
        (.taskDefinitionArn | split("/") | last) as $task_def |
        .lastStatus as $status |
        (.startedAt // "N/A") as $started |
        .containers[] |
        [.name, $task_def, $service_display, $cluster_display, $cluster_logical, $service_logical, $task_id, $task_arn, $status, $started, (.image // "N/A"), (.healthStatus // "N/A")] |
        @tsv
      ' >> "${entries_file}" 2>/dev/null || true

    done <<< "${service_names}"
  done <<< "${cluster_names}"

  if [[ ! -s "${entries_file}" ]]; then
    echo "No running tasks/containers found." >&2
    exit 1
  fi
}

###############################################################################
# Hierarchical fzf selection with preview (table view)
###############################################################################
_pick_container() {
  local entries_file="${TMPDIR_CACHE}/entries.tsv"

  # TSV columns: 1=container_name 2=task_display 3=service_display 4=cluster_display
  #              5=cluster_logical 6=service_logical 7=task_id 8=task_arn
  #              9=status 10=started 11=image 12=health

  # Build table display with line numbers prepended (for selection tracking)
  local display_file="${TMPDIR_CACHE}/display.txt"
  awk -F'\t' '
    BEGIN { fmt = "%d\t\033[1;36m%-30s\033[0m  \033[1;33m%-30s\033[0m  \033[1;32m%-25s\033[0m  \033[1;34m%-20s\033[0m\n" }
    { printf fmt, NR, substr($1,1,30), substr($2,1,30), substr($3,1,25), substr($4,1,20) }
  ' "${entries_file}" > "${display_file}"

  # Table header
  local header
  header=$(printf "%-30s  %-30s  %-25s  %-20s" "CONTAINER" "TASK" "SERVICE" "CLUSTER")

  # Preview script — shows full details for highlighted entry
  local preview_script="${TMPDIR_CACHE}/preview.sh"
  cat > "${preview_script}" << PREVIEW
#!/usr/bin/env bash
line_num=\$(echo "\$1" | cut -f1)
entries_file="${entries_file}"
line=\$(sed -n "\${line_num}p" "\${entries_file}")
IFS=\$'\t' read -r container task_display service_display cluster_display cluster_logical service_logical task_id task_arn status started image health <<< "\${line}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              Container Details                       ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║"
printf "║  %-14s %s\n" "Container:" "\${container}"
printf "║  %-14s %s\n" "Task Def:" "\${task_display}"
printf "║  %-14s %s\n" "Service:" "\${service_display}"
printf "║  %-14s %s\n" "Cluster:" "\${cluster_display}"
echo "║"
echo "║  ── Identifiers ──"
printf "║  %-14s %s\n" "Task ID:" "\${task_id}"
printf "║  %-14s %s\n" "Task ARN:" "\${task_arn}"
printf "║  %-14s %s\n" "Cluster ID:" "\${cluster_logical}"
printf "║  %-14s %s\n" "Service ID:" "\${service_logical}"
echo "║"
echo "║  ── Status ──"
printf "║  %-14s %s\n" "Status:" "\${status}"
printf "║  %-14s %s\n" "Started:" "\${started}"
printf "║  %-14s %s\n" "Image:" "\${image}"
printf "║  %-14s %s\n" "Health:" "\${health}"
echo "║"
echo "╚══════════════════════════════════════════════════════╝"
PREVIEW
  chmod +x "${preview_script}"

  local selected_line
  selected_line=$(cat "${display_file}" | \
    fzf --ansi \
        --prompt="Select container > " \
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

  # Extract line number from first field, then get the TSV data
  local line_num
  line_num=$(echo "${selected_line}" | cut -f1)

  sed -n "${line_num}p" "${entries_file}"
}

###############################################################################
# Command picker
###############################################################################
_pick_command() {
  local commands=(
    "/bin/sh"
    "/bin/bash"
    "/bin/ash"
    "Custom..."
  )

  local selected
  selected=$(printf '%s\n' "${commands[@]}" | \
    fzf --prompt="Command > " \
        --header="Select command to execute" \
        --border \
        --height=30%)

  if [[ -z "${selected}" ]]; then
    echo "Cancelled." >&2
    exit 1
  fi

  if [[ "${selected}" == "Custom..." ]]; then
    read -r -p "Enter custom command: " selected
    if [[ -z "${selected}" ]]; then
      echo "No command entered. Cancelled." >&2
      exit 1
    fi
  fi

  echo "${selected}"
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

  # Step 2: Fetch ECS data
  _fetch_ecs_data "${profile_flag}" "${REGION_FLAG}"

  # Step 3: Pick container from hierarchical view
  local selected_entry
  selected_entry=$(_pick_container)

  IFS=$'\t' read -r container_name task_display service_display cluster_display cluster_logical service_logical task_id task_arn status started image health <<< "${selected_entry}"

  echo ""
  echo "Selected:"
  echo "  Container: ${container_name}"
  echo "  Task:      ${task_display} (${task_id})"
  echo "  Service:   ${service_display} (${service_logical})"
  echo "  Cluster:   ${cluster_display} (${cluster_logical})"
  echo ""

  # Step 4: Pick command
  local cmd
  cmd=$(_pick_command)

  # Step 5: Execute
  echo ""
  echo "Executing:"
  echo "  aws ${profile_flag} ${REGION_FLAG} ecs execute-command \\"
  echo "    --cluster ${cluster_logical} \\"
  echo "    --task ${task_id} \\"
  echo "    --container ${container_name} \\"
  echo "    --command \"${cmd}\" \\"
  echo "    --interactive"
  echo ""

  eval aws "${profile_flag}" ${REGION_FLAG} ecs execute-command \
    --cluster "${cluster_logical}" \
    --task "${task_id}" \
    --container "${container_name}" \
    --command "${cmd}" \
    --interactive
}

main "$@"
