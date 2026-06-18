#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# get-secret-helper.sh
#
# A modern AWS Secrets Manager helper using fzf for interactive selection.
# Features: fuzzy profile/secret selection, preview pane with metadata,
# JSON key extraction, and clipboard support.
#
# Dependencies: aws (v2), fzf, jq
# Optional: xclip, xsel, pbcopy, or wl-copy (for clipboard)
###############################################################################

readonly VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Colours
readonly C_BLUE='\033[1;34m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[1;36m'
readonly C_DIM='\033[2m'
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

A modern helper script to select and view AWS Secrets Manager secrets.

Uses fzf for interactive fuzzy selection of:
  - AWS profile (from ~/.aws/config) — skipped if --profile is provided
  - Secret (with metadata preview)
  - JSON key extraction (if secret is JSON)

Options:
  -h, --help       Print this help and exit
  -p, --profile    AWS profile to use (bypasses fzf profile selection)
  -r, --region     AWS region override (otherwise uses profile default)
  -v, --version    Print version and exit

Requirements:
  - aws CLI v2
  - fzf (https://github.com/junegunn/fzf)
  - jq (https://stedolan.github.io/jq/)

Optional (for clipboard):
  - xclip, xsel, pbcopy (macOS), or wl-copy (Wayland)
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
# Clipboard detection
###############################################################################
_get_clipboard_cmd() {
  if command -v pbcopy &>/dev/null; then
    echo "pbcopy"
  elif command -v wl-copy &>/dev/null; then
    echo "wl-copy"
  elif command -v xclip &>/dev/null; then
    echo "xclip -selection clipboard"
  elif command -v xsel &>/dev/null; then
    echo "xsel --clipboard --input"
  else
    echo ""
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
# Fetch secrets list with metadata
###############################################################################
_fetch_secrets() {
  local profile_flag="$1"
  local region_flag="$2"
  local aws_cmd="aws ${profile_flag} ${region_flag}"

  echo "Fetching secrets..." >&2

  local secrets_json
  if ! secrets_json=$(eval ${aws_cmd} secretsmanager list-secrets --output json 2>&1); then
    echo "Error fetching secrets list:" >&2
    echo "${secrets_json}" >&2
    exit 1
  fi

  echo "${secrets_json}" > "${TMPDIR_CACHE}/secrets.json"

  local count
  count=$(echo "${secrets_json}" | jq '.SecretList | length' 2>/dev/null || echo "0")

  if [[ "${count}" == "0" || "${count}" == "null" ]]; then
    echo "No secrets found in this account/region." >&2
    exit 1
  fi

  # Build entries TSV: secret_name \t display_name \t description \t created \t last_accessed \t tags_str
  local entries_file="${TMPDIR_CACHE}/entries.tsv"
  echo "${secrets_json}" | jq -r '
    .SecretList[] |
    .Name as $secret_name |
    (.Tags // []) as $tags |
    ($tags | map(select(.Key == "Name")) | if length > 0 then .[0].Value else $secret_name end) as $display_name |
    (.Description // "N/A") as $desc |
    (.CreatedDate // "N/A" | tostring) as $created |
    (.LastAccessedDate // "N/A" | tostring) as $accessed |
    ($tags | map(.Key + "=" + .Value) | join(", ")) as $tags_str |
    [$secret_name, $display_name, $desc, $created, $accessed, $tags_str] |
    @tsv
  ' > "${entries_file}" 2>/dev/null || true

  if [[ ! -s "${entries_file}" ]]; then
    echo "Error: could not parse secrets list. Raw response saved to ${TMPDIR_CACHE}/secrets.json" >&2
    exit 1
  fi
}

###############################################################################
# Pick secret with fzf + preview pane
###############################################################################
_pick_secret() {
  local entries_file="${TMPDIR_CACHE}/entries.tsv"

  # Build display: line_num \t display_name (secret_name)
  local display_file="${TMPDIR_CACHE}/display.txt"
  awk -F'\t' '{printf "%d\t\033[1;36m%-40s\033[0m  \033[2m%s\033[0m\n", NR, $2, $1}' \
    "${entries_file}" > "${display_file}"

  local header
  header=$(printf "%-40s  %s" "NAME" "SECRET ID")

  # Preview script
  local preview_script="${TMPDIR_CACHE}/preview.sh"
  cat > "${preview_script}" << PREVIEW
#!/usr/bin/env bash
line_num=\$(echo "\$1" | cut -f1)
entries_file="${entries_file}"
line=\$(sed -n "\${line_num}p" "\${entries_file}")
IFS=\$'\t' read -r secret_name display_name description created accessed tags_str <<< "\${line}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║              Secret Metadata                         ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║"
printf "║  %-16s %s\n" "Display Name:" "\${display_name}"
printf "║  %-16s %s\n" "Secret Name:" "\${secret_name}"
printf "║  %-16s %s\n" "Description:" "\${description}"
printf "║  %-16s %s\n" "Created:" "\${created}"
printf "║  %-16s %s\n" "Last Accessed:" "\${accessed}"
echo "║"
if [[ -n "\${tags_str}" && "\${tags_str}" != "" ]]; then
  echo "║  ── Tags ──"
  IFS=',' read -ra tag_pairs <<< "\${tags_str}"
  for tag in "\${tag_pairs[@]}"; do
    printf "║    %s\n" "\$(echo \${tag} | xargs)"
  done
fi
echo "║"
echo "╚══════════════════════════════════════════════════════╝"
PREVIEW
  chmod +x "${preview_script}"

  local selected_line
  selected_line=$(cat "${display_file}" | \
    fzf --ansi \
        --prompt="Select secret > " \
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
  local secret_name
  secret_name=$(sed -n "${line_num}p" "${entries_file}" | cut -f1)

  echo "${secret_name}"
}

###############################################################################
# Fetch and display secret value, with JSON key extraction
###############################################################################
_display_secret() {
  local profile_flag="$1"
  local region_flag="$2"
  local secret_name="$3"
  local aws_cmd="aws ${profile_flag} ${region_flag}"

  echo "Fetching secret value..." >&2

  local secret_response
  if ! secret_response=$(eval ${aws_cmd} secretsmanager get-secret-value --secret-id "${secret_name}" --output json 2>&1); then
    echo "Error fetching secret: ${secret_response}" >&2
    exit 1
  fi

  # Extract the secret string
  local secret_value
  secret_value=$(echo "${secret_response}" | jq -r '.SecretString // empty')

  if [[ -z "${secret_value}" ]]; then
    # Maybe it's binary
    local secret_binary
    secret_binary=$(echo "${secret_response}" | jq -r '.SecretBinary // empty')
    if [[ -n "${secret_binary}" ]]; then
      echo ""
      echo "Secret is binary (base64-encoded):"
      echo "${secret_binary}"
      echo "${secret_binary}" > "${TMPDIR_CACHE}/secret_value.txt"
      return
    fi
    echo "Error: secret has no value." >&2
    exit 1
  fi

  # Try to parse as JSON
  local is_json=false
  if echo "${secret_value}" | jq . &>/dev/null; then
    is_json=true
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Secret: ${secret_name}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  if [[ "${is_json}" == "true" ]]; then
    echo "${secret_value}" | jq --color-output .
    echo ""

    # Offer to extract a specific key
    local keys
    keys=$(echo "${secret_value}" | jq -r 'if type == "object" then keys[] else empty end' 2>/dev/null || true)

    if [[ -n "${keys}" ]]; then
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""

      # Save secret to temp file for preview to read safely
      echo "${secret_value}" > "${TMPDIR_CACHE}/secret_json.txt"

      local extract_choice
      extract_choice=$(printf '%s\n' "[ Copy entire secret ]" ${keys} | \
        fzf --prompt="Extract key > " \
            --header="Select a key to extract (or entire secret)" \
            --border \
            --height=40% \
            --preview="jq -r --arg key {} '.[\$key] // \"(entire secret)\"' ${TMPDIR_CACHE}/secret_json.txt" 2>/dev/null || true)

      if [[ -n "${extract_choice}" && "${extract_choice}" != "[ Copy entire secret ]" ]]; then
        local extracted_value
        extracted_value=$(echo "${secret_value}" | jq -r --arg key "${extract_choice}" '.[$key]')
        echo ""
        echo "  Key: ${extract_choice}"
        echo "  Value: ${extracted_value}"
        echo ""
        echo "${extracted_value}" > "${TMPDIR_CACHE}/secret_value.txt"
        return
      fi
    fi
  else
    echo "${secret_value}"
    echo ""
  fi

  echo "${secret_value}" > "${TMPDIR_CACHE}/secret_value.txt"
}

###############################################################################
# Clipboard copy (auto-copy, no prompt)
###############################################################################
_copy_to_clipboard() {
  local value_file="${TMPDIR_CACHE}/secret_value.txt"

  if [[ ! -f "${value_file}" ]]; then
    return
  fi

  local clip_cmd
  clip_cmd=$(_get_clipboard_cmd)

  if [[ -z "${clip_cmd}" ]]; then
    echo -e "${C_DIM}(No clipboard tool detected — install xclip, xsel, or wl-copy to enable copy)${C_RESET}"
    return
  fi

  eval ${clip_cmd} < "${value_file}"
  echo "✓ Copied to clipboard."
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

  # Step 2: Fetch secrets list
  _fetch_secrets "${profile_flag}" "${REGION_FLAG}"

  # Step 3: Pick a secret
  local secret_name
  secret_name=$(_pick_secret)
  echo "Selected: ${secret_name}"

  # Step 4: Display secret value (with optional key extraction)
  _display_secret "${profile_flag}" "${REGION_FLAG}" "${secret_name}"

  # Step 5: Auto-copy to clipboard
  _copy_to_clipboard
}

main "$@"
