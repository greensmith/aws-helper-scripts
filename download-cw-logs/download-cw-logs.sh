#!/usr/bin/env bash

# TODO: add date/time selector

_help() {
  cat << EOF
    $(basename "${BASH_SOURCE[0]}") [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]

    A helper script to select and download aws cloudwatch logs

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

# midnight this morning in unix time
start_time=$(date -d 'today 00:00:00' +%s%3N)

log_groups=$(aws ${profile} ${region} logs describe-log-groups --query "logGroups[*].logGroupName" --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr -d '"' | tr "," " ")


PS3="Please select the log group :"$'\n'
select log_group in $log_groups
do
  echo "The log group value is: "
  echo "${log_group}"
  export selected_log_group=$log_group
  break
done

log_streams=$(aws ${profile} ${region} logs describe-log-streams --log-group-name $selected_log_group --query "logStreams[*].logStreamName" --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr -d '"' | tr "," " ")


PS3="Please select the log stream prefix :"$'\n'
select log_stream in $log_streams
do
  echo "The log stream prefix value is: "
  echo "${log_stream}"
  export selected_log_stream=$log_stream
  break
done

result=$(aws ${profile} ${region} logs get-log-events \
    --start-from-head \
    --start-time=${start_time} \
    --log-group-name=${selected_log_group} \
    --log-stream-name=${selected_log_stream})
echo ${result} | jq -r .events[].message >> output.log

nextToken=$(echo $result | jq -r .nextForwardToken)
while [ -n "$nextToken" ]; do
    echo ${nextToken}
    result=$(aws logs ${profile} ${region} get-log-events \
        --start-from-head \
        --start-time=${start_time} \
        --log-group-name=${selected_log_group} \
        --log-stream-name=${selected_log_stream} \
        --next-token="${nextToken}")

    if [[ $(echo ${result} | jq -e '.events == []') == "true" ]]; then
        echo "response with empty events found -> exiting."
        exit
    fi

    echo ${result} | jq -r .events[].message >> output.log

    nextToken=$(echo ${result} | jq -r .nextForwardToken)
done