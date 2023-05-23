#!/usr/bin/env bash

# TODO - make cluster/service selection more user friendly
# TODO - add way to handle desired counts > 1

_help() {
  cat << EOF
    $(basename "${BASH_SOURCE[0]}") [-h] [-p profile] [-r region]  [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
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


#########
##
#
#   We need to find the following information and map it accordingly
#
#   the CLUSTERs that are running on the account
#   the SERVICESs that are running in the cluster
#   TODO: make it look prettier with the names etc. using jq


echo "this is going to turn on all ecs services"

# start with an array of clusters
clusters=($(aws ${profile} ${region} ecs list-clusters --query 'clusterArns[]' --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr "," " "))

# Prompt user to select a cluster
PS3="Please enter the number of the cluster :"$'\n'
select cluster in ${clusters[@]}; do
  # Set selected cluster as environment variable
  export SELECTED_CLUSTER=$(echo $cluster | awk -F/ '{print $NF}' |  tr '"' ' ')
  break
done


# are you sure you want to do this?
read -p "Are you sure you want to turn on all ecs services? (y/n) " -n 1 -r


# get the services
services=($(aws ${profile} ${region} ecs list-services --cluster $SELECTED_CLUSTER --query 'serviceArns[]' --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr "," " "))
echo $services
# for each service
for service in "${services[@]}"
do
  echo "Starting: $service"
  # stop the service
  SELECTED_SERVICE=$(echo $service | awk -F/ '{print $NF}' |  tr '"' ' ')
  aws ${profile} ${region} ecs update-service --cluster $SELECTED_CLUSTER --service $SELECTED_SERVICE --desired-count 1  --query "service.[serviceName,desiredCount]"
done


echo "All services started"