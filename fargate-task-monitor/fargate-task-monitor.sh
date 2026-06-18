#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# fargate-task-monitor.sh
#
# A Fargate task monitor with fzf table view and CloudWatch log tailing.
# Shows running tasks across all clusters/services with Name tags,
# then tails CloudWatch logs for the selected container.
#
# Dependencies: aws (v2), fzf, jq
###############################################################################

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Colours
readonly C_BLUE='\033[1;34m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[1;36m'
readonly C_DIM='\033[2m'
readonly C_BOLD='\033[1m'
readonly C_RED='\033[1;31m'
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
Usage: ${SCRIPT_NAME} [-h] [-p profile] [-r region] [-s minutes]

A Fargate task monitor that displays running tasks in a table and tails
CloudWatch logs for the selected container.

Uses fzf for interactive fuzzy selection of:
  - AWS profile (from ~/.aws/config) — skipped if --profile is provided
  - Container to monitor (hierarchical table view with preview)

After selecting a container, the script tails its CloudWatch logs.
Press Ctrl+C to stop tailing and return to the container table.
Press Esc or Ctrl+C on the table to exit.

Options:
  -h, --help       Print this help and exit
  -p, --profile    AWS profile to use (bypasses fzf profile selection)
  -r, --region     AWS region override (otherwise uses profile default)
  -s, --since      Minutes of historical logs to fetch before tailing (default: 5)
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
SINCE_MINUTES="5"

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
      -s|--since)
        SINCE_MINUTES="${2-}"
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
# Fetch ECS data with log configuration
###############################################################################
_fetch_ecs_data() {
  local profile_flag="$1"
  local region_flag="$2"
  local aws_cmd="aws ${profile_flag} ${region_flag}"

  echo "Fetching ECS clusters..." >&2

  local clusters_json
  if ! clusters_json=$(eval ${aws_cmd} ecs list-clusters --output json 2>&1); then
    echo "Error fetching clusters:" >&2
    echo "${clusters_json}" >&2
    exit 1
  fi

  local cluster_arns
  cluster_arns=$(echo "${clusters_json}" | jq -r '.clusterArns[]' 2>/dev/null || true)

  if [[ -z "${cluster_arns}" ]]; then
    echo "No ECS clusters found." >&2
    exit 1
  fi

  # Describe clusters with tags
  local clusters_detail
  clusters_detail=$(eval ${aws_cmd} ecs describe-clusters \
    --clusters $(echo "${cluster_arns}" | tr '\n' ' ') \
    --include TAGS \
    --output json)
  echo "${clusters_detail}" > "${TMPDIR_CACHE}/clusters.json"

  # Build entries TSV:
  # container_name \t task_display \t service_display \t cluster_display \t
  # cluster_logical \t service_logical \t task_id \t task_arn \t status \t
  # started \t image \t health \t log_group \t log_stream_prefix \t log_region
  local entries_file="${TMPDIR_CACHE}/entries.tsv"
  > "${entries_file}"

  # Build cluster name lookup
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

    # Describe services with tags
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

      # List tasks
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

      # Describe tasks
      local tasks_detail
      tasks_detail=$(eval ${aws_cmd} ecs describe-tasks \
        --cluster "${cluster_name}" \
        --tasks $(echo "${task_arns}" | tr '\n' ' ') \
        --output json 2>/dev/null || echo '{"tasks":[]}')
      echo "${tasks_detail}" > "${TMPDIR_CACHE}/tasks_${cluster_name}_${service_name}.json"

      # Get task definition ARNs to look up log config
      local task_def_arns
      task_def_arns=$(echo "${tasks_detail}" | jq -r '.tasks[].taskDefinitionArn' 2>/dev/null | sort -u || true)

      # Cache task definitions for log config lookup
      while IFS= read -r td_arn; do
        [[ -z "${td_arn}" ]] && continue
        local td_key
        td_key=$(echo "${td_arn}" | tr '/:' '__')
        if [[ ! -f "${TMPDIR_CACHE}/taskdef_${td_key}.json" ]]; then
          eval ${aws_cmd} ecs describe-task-definition \
            --task-definition "${td_arn}" \
            --output json > "${TMPDIR_CACHE}/taskdef_${td_key}.json" 2>/dev/null || true
        fi
      done <<< "${task_def_arns}"

      # Extract entries with log config from task definitions
      local task_count
      task_count=$(echo "${tasks_detail}" | jq '.tasks | length')

      for ti in $(seq 0 $((task_count - 1))); do
        local task_arn task_id task_def_arn task_def_display status started
        task_arn=$(echo "${tasks_detail}" | jq -r ".tasks[${ti}].taskArn")
        task_id=$(echo "${task_arn}" | awk -F/ '{print $NF}')
        task_def_arn=$(echo "${tasks_detail}" | jq -r ".tasks[${ti}].taskDefinitionArn")
        task_def_display=$(echo "${task_def_arn}" | awk -F/ '{print $NF}')
        status=$(echo "${tasks_detail}" | jq -r ".tasks[${ti}].lastStatus")
        started=$(echo "${tasks_detail}" | jq -r ".tasks[${ti}].startedAt // \"N/A\"")

        local td_key
        td_key=$(echo "${task_def_arn}" | tr '/:' '__')
        local td_file="${TMPDIR_CACHE}/taskdef_${td_key}.json"

        local container_count
        container_count=$(echo "${tasks_detail}" | jq ".tasks[${ti}].containers | length")

        for ci in $(seq 0 $((container_count - 1))); do
          local container_name image health
          container_name=$(echo "${tasks_detail}" | jq -r ".tasks[${ti}].containers[${ci}].name")
          image=$(echo "${tasks_detail}" | jq -r ".tasks[${ti}].containers[${ci}].image // \"N/A\"")
          health=$(echo "${tasks_detail}" | jq -r ".tasks[${ti}].containers[${ci}].healthStatus // \"N/A\"")

          # Look up log config from task definition
          local log_group="N/A" log_stream_prefix="N/A" log_region="N/A"
          if [[ -f "${td_file}" ]]; then
            log_group=$(jq -r --arg cn "${container_name}" '
              .taskDefinition.containerDefinitions[] |
              select(.name == $cn) |
              .logConfiguration // {} |
              select(.logDriver == "awslogs") |
              .options["awslogs-group"] // "N/A"
            ' "${td_file}" 2>/dev/null || echo "N/A")

            log_stream_prefix=$(jq -r --arg cn "${container_name}" '
              .taskDefinition.containerDefinitions[] |
              select(.name == $cn) |
              .logConfiguration // {} |
              select(.logDriver == "awslogs") |
              .options["awslogs-stream-prefix"] // "N/A"
            ' "${td_file}" 2>/dev/null || echo "N/A")

            log_region=$(jq -r --arg cn "${container_name}" '
              .taskDefinition.containerDefinitions[] |
              select(.name == $cn) |
              .logConfiguration // {} |
              select(.logDriver == "awslogs") |
              .options["awslogs-region"] // "N/A"
            ' "${td_file}" 2>/dev/null || echo "N/A")
          fi

          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${container_name}" "${task_def_display}" "${service_display}" "${cluster_display}" \
            "${cluster_name}" "${service_name}" "${task_id}" "${task_arn}" \
            "${status}" "${started}" "${image}" "${health}" \
            "${log_group}" "${log_stream_prefix}" "${log_region}" \
            >> "${entries_file}"
        done
      done

    done <<< "${service_names}"
  done <<< "${cluster_names}"

  if [[ ! -s "${entries_file}" ]]; then
    echo "No running tasks/containers found." >&2
    exit 1
  fi
}

###############################################################################
# Pick container from fzf table with preview
###############################################################################
_pick_container() {
  local entries_file="${TMPDIR_CACHE}/entries.tsv"

  # TSV columns:
  # 1=container 2=task_def 3=service_display 4=cluster_display
  # 5=cluster_logical 6=service_logical 7=task_id 8=task_arn
  # 9=status 10=started 11=image 12=health
  # 13=log_group 14=log_stream_prefix 15=log_region

  local display_file="${TMPDIR_CACHE}/display.txt"
  awk -F'\t' '
    BEGIN { fmt = "%d\t\033[1;36m%-28s\033[0m  \033[1;33m%-28s\033[0m  \033[1;32m%-22s\033[0m  \033[1;34m%-18s\033[0m  \033[2m%-8s\033[0m\n" }
    { printf fmt, NR, substr($1,1,28), substr($2,1,28), substr($3,1,22), substr($4,1,18), $9 }
  ' "${entries_file}" > "${display_file}"

  local header
  header=$(printf "%-28s  %-28s  %-22s  %-18s  %-8s" "CONTAINER" "TASK" "SERVICE" "CLUSTER" "STATUS")

  # Preview script
  local preview_script="${TMPDIR_CACHE}/preview.sh"
  cat > "${preview_script}" << PREVIEW
#!/usr/bin/env bash
line_num=\$(echo "\$1" | cut -f1)
entries_file="${entries_file}"
line=\$(sed -n "\${line_num}p" "\${entries_file}")
IFS=\$'\t' read -r container task_def service_display cluster_display cluster_logical service_logical task_id task_arn status started image health log_group log_prefix log_region <<< "\${line}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              Container Details                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║"
printf "║  %-16s %s\n" "Container:" "\${container}"
printf "║  %-16s %s\n" "Task Def:" "\${task_def}"
printf "║  %-16s %s\n" "Service:" "\${service_display}"
printf "║  %-16s %s\n" "Cluster:" "\${cluster_display}"
echo "║"
echo "║  ── Identifiers ──"
printf "║  %-16s %s\n" "Task ID:" "\${task_id}"
printf "║  %-16s %s\n" "Cluster ID:" "\${cluster_logical}"
printf "║  %-16s %s\n" "Service ID:" "\${service_logical}"
echo "║"
echo "║  ── Status ──"
printf "║  %-16s %s\n" "Status:" "\${status}"
printf "║  %-16s %s\n" "Started:" "\${started}"
printf "║  %-16s %s\n" "Image:" "\${image}"
printf "║  %-16s %s\n" "Health:" "\${health}"
echo "║"
echo "║  ── Log Configuration ──"
if [[ "\${log_group}" != "N/A" ]]; then
  printf "║  %-16s %s\n" "Log Group:" "\${log_group}"
  printf "║  %-16s %s\n" "Stream Prefix:" "\${log_prefix}"
  printf "║  %-16s %s\n" "Log Region:" "\${log_region}"
  log_stream="\${log_prefix}/\${container}/\${task_id}"
  printf "║  %-16s %s\n" "Log Stream:" "\${log_stream}"
else
  echo "║  ⚠  No awslogs configuration found"
fi
echo "║"
echo "╚══════════════════════════════════════════════════════════╝"
PREVIEW
  chmod +x "${preview_script}"

  local selected_line
  selected_line=$(cat "${display_file}" | \
    fzf --ansi \
        --prompt="Select container to tail > " \
        --header="${header}" \
        --border \
        --height=80% \
        --preview="${preview_script} {}" \
        --preview-window=right:45%:wrap \
        --with-nth=2.. \
        --delimiter=$'\t' \
        --expect=esc 2>/dev/null || true)

  if [[ -z "${selected_line}" ]]; then
    echo "__EXIT__"
    return
  fi

  # fzf --expect outputs the key on the first line, selection on the second
  local key_pressed
  key_pressed=$(echo "${selected_line}" | head -1)
  local selection
  selection=$(echo "${selected_line}" | tail -1)

  if [[ "${key_pressed}" == "esc" || -z "${selection}" ]]; then
    echo "__EXIT__"
    return
  fi

  local line_num
  line_num=$(echo "${selection}" | cut -f1)

  sed -n "${line_num}p" "${entries_file}"
}

###############################################################################
# Tail CloudWatch logs
###############################################################################
_tail_logs() {
  local profile_flag="$1"
  local region_flag="$2"
  local container_name="$3"
  local task_id="$4"
  local log_group="$5"
  local log_stream_prefix="$6"
  local log_region="$7"
  local since_minutes="$8"

  # Construct log stream prefix path: prefix/container-name/task-id
  local log_stream="${log_stream_prefix}/${container_name}/${task_id}"

  # Use log region if available, otherwise use the general region flag
  local log_region_flag="${region_flag}"
  if [[ "${log_region}" != "N/A" && -n "${log_region}" ]]; then
    log_region_flag="--region ${log_region}"
  fi

  echo ""
  echo -e "${C_BOLD}Tailing logs for:${C_RESET}"
  echo -e "  Container: ${C_CYAN}${container_name}${C_RESET}"
  echo -e "  Log Group: ${C_GREEN}${log_group}${C_RESET}"
  echo -e "  Log Stream: ${C_YELLOW}${log_stream}${C_RESET}"
  echo -e "  Since: ${since_minutes}m ago"
  echo ""
  echo -e "${C_DIM}Press Ctrl+C to stop tailing and return to container list${C_RESET}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Tail with --follow and --since
  local log_stream_prefix_path="${log_stream_prefix}/${container_name}/${task_id}"

  # Build command array to avoid eval quoting issues
  local -a cmd=(aws)
  [[ -n "${profile_flag}" ]] && read -ra _pf <<< "${profile_flag}" && cmd+=("${_pf[@]}")
  [[ -n "${log_region_flag}" ]] && read -ra _rf <<< "${log_region_flag}" && cmd+=("${_rf[@]}")
  cmd+=(logs tail "${log_group}"
    --log-stream-name-prefix "${log_stream_prefix_path}"
    --follow
    --since "${since_minutes}m"
    --format short)

  echo -e "${C_DIM}${cmd[*]}${C_RESET}"
  echo ""

  "${cmd[@]}" 2>&1 || true
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

  # Step 3: Selection loop
  while true; do
    local selected_entry
    selected_entry=$(_pick_container)

    if [[ "${selected_entry}" == "__EXIT__" ]]; then
      echo "Exiting."
      break
    fi

    IFS=$'\t' read -r container_name task_def service_display cluster_display \
      cluster_logical service_logical task_id task_arn status started image health \
      log_group log_stream_prefix log_region <<< "${selected_entry}"

    if [[ "${log_group}" == "N/A" || -z "${log_group}" ]]; then
      echo ""
      echo -e "${C_RED}Error: No awslogs configuration found for container '${container_name}'.${C_RESET}"
      echo "This container may not use the awslogs log driver."
      echo ""
      read -r -p "Press Enter to return to the container list..."
      continue
    fi

    # Tail logs (Ctrl+C returns here)
    _tail_logs "${profile_flag}" "${REGION_FLAG}" \
      "${container_name}" "${task_id}" \
      "${log_group}" "${log_stream_prefix}" "${log_region}" \
      "${SINCE_MINUTES}"

    echo ""
    echo -e "${C_DIM}Returning to container list...${C_RESET}"
    echo ""
  done
}

main "$@"
