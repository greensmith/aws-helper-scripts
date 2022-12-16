#!/usr/bin/env bash

_help() {
  cat << EOF
    $(basename "${BASH_SOURCE[0]}") [-h] [-p profile] [-r region]  [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]

    A helper script to select and execute commands on fargate containers

    You will be prompted to first select a cluster
    then a task running on that cluster
    followed by a container inside that task.

    Finally you will be asked what command you wish to interactively execute

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
#   the TASKs that are running in the service
#   the CONTAINERs that are running the the task
#
#   therefore our map that we wish to refer to each object would have the following propeties
#   item:
#     cluster: cluster_id
#     task: task_id
#     container: container_name


# To do list
# TODO: lookup names of tasks so they are not presented as id's
# TODO: make prettier and easier to read
# TODO: optionally pass task id/container and lookup other information.

# start with an array of clusters
clusters=($(aws ${profile} ${region} ecs list-clusters --query 'clusterArns[]' --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr "," " "))


# Prompt user to select a cluster
PS3="Please enter the number of the cluster :"$'\n'
select cluster in ${clusters[@]}; do
  # Set selected cluster as environment variable
  export SELECTED_CLUSTER=$(echo $cluster | awk -F/ '{print $NF}' |  tr '"' ' ')
  break
done

tasks=($(aws ${profile} ${region} ecs list-tasks --cluster $SELECTED_CLUSTER --query "taskArns[]" --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr "," " "))

# Prompt user to select a task
PS3="Please enter the number of the task :"$'\n'
select task in ${tasks[@]}; do
  # Set selected cluster as environment variable
  export SELECTED_TASK=$(echo $task | awk -F/ '{print $NF}' |  tr '"' ' ')
  break
done

containers=($(aws ${profile} ${region} ecs describe-tasks --tasks ${SELECTED_TASK} --cluster ${SELECTED_CLUSTER} --query "tasks[*][containers[*][name]]" --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr "," " "))

# Prompt user to select a task
PS3="Please enter the number of the container :"$'\n'
select container in ${containers[@]}; do
  # Set selected cluster as environment variable
  export SELECTED_CONTAINER=$(echo $container | awk -F/ '{print $NF}' |  tr '"' ' ')
  break
done

# run ecs exec
read -p 'Please type the command to exec interactively, default: /bin/bash : ' execCMD
execCMD=${name:-/bin/bash}

aws $profile $region ecs execute-command  \
    --cluster $SELECTED_CLUSTER \
    --task $SELECTED_TASK \
    --container $SELECTED_CONTAINER \
    --command $execCMD \
    --interactive
