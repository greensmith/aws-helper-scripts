#!/usr/bin/env bash

_help() {
  cat << EOF
    $(basename "${BASH_SOURCE[0]}") [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]

    A helper script to select and tail aws cloudwatch logs

    You will be prompted to select a log group and a enter a log stream prefix

    Options:

    -h, --help      Print this help
    -p, --profile    the aws profile to use (if no profile specified uses default)
    -r, --region    the aws profile to use (if no region specified uses default)
EOF
  exit
}


_params() {

  # default values
  region=''
  profile=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    #-v | --verbose) set -x ;;
    -p | --profile) # aws profile
      profile="--profile ${2-}"
      shift
      ;;
    -r | --region) # aws region
      region="--region ${2-}"
      shift
      ;;
    -?*) echo "Option: $1 is not recognised"; exit 1 ;;
    *) break ;;
    esac
    shift
  done
  args=("$@")
  return 0
}

_params "$@"

log_groups=$(aws ${profile} ${region} logs describe-log-groups --query "logGroups[*].logGroupName" --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr -d '"' | tr "," " ")



PS3="Please select the log group :"$'\n'
select log_group in $log_groups
do
  # Use the AWS CLI to get the Secret value
  #secret_value=$(aws ${profile} ${region} secretsmanager get-secret-value --secret-id $secret)

  # Print the Secret value to the console
  echo "The log group value is: "
  echo "${log_group}"
  selected_log_group=$log_group
  break
done

# choose log stream prefix
read -p 'Please type the log stream prefix to monitor, default: monitor all streams in log group : ' log_stream_prefix

if [[ -z "${log_stream_prefix}" ]]
then
    aws $profile $region logs tail $selected_log_group --follow --format short
else
    aws $profile $region logs tail $selected_log_group --log-stream-name-prefix $log_stream_prefix --follow --format short
fi

