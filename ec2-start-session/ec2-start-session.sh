#!/usr/bin/env bash

_help() {
  cat << EOF
    $(basename "${BASH_SOURCE[0]}") [-h] [-p profile] [-r region]  [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]

    A helper script to select and execute shell session on ec2 instance

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


# get a json object of  ec2 instances
instances_names=$(aws $profile $region ec2 describe-instances --filter "Name=instance-state-name,Values=running" | jq -r '.Reservations[].Instances[].Tags[] | select(.Key == "Name") | .Value ')


PS3="Please select the instance :"$'\n'
select instance in $instances_names
do
  instance_id=$(aws $profile $region ec2 describe-instances --filter "Name=tag:Name,Values=$instance" | jq -r '.Reservations[].Instances[].InstanceId')
  echo "The instance name is: "
  echo "${instance}"
  echo "The instance id is: "
  echo "${instance_id}"
  break
done


# start and ssm session on the selected instance
aws $profile $region ssm start-session --target $instance_id