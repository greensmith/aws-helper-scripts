#!/usr/bin/env bash

# plan of action
# 1. get a list of all the AWS RDS databases
# 2. prompt user to select the database to be dumped
# 3. get the rds instance details
# 4. get a list of all the AWS Secrets Manager secrets
# 5. prompt user to select the secret that matches this db (is there a more efficient way to do this?)
# 6. get the secret details
# 7. get s3 bucket
# 8. run a container with custom image that dumps the db and uploads it to s3
# 9. (optional) download dump from s3 bucket


_help() {
  cat << EOF
    $(basename "${BASH_SOURCE[0]}") [-h] [-p profile] [-r region]  [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]

    A helper script to dump a mysql db

    Options:

    -h, --help      Print this help
    -p, --profile    the aws profile to use (if no profile specified uses default)
    -r, --region    the aws profile to use (if no region specified uses default)
    --s3_bucket   the s3 bucket to use
    --s3_bucket_region   the s3 bucket region to use
    --rds_instance_name the rds db to use
    --secret_name the secret to use
    --subnet_name the subnet to use
    --cluster_name the cluster to use
    --db_name the db to dump

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
    --s3_bucket) # s3 bucket to use
      s3_bucket="${2-}"
      shift
      ;;
    --s3_bucket_region) # s3 bucket region to use
      s3_bucket_region="${2-}"
      shift
      ;;
    --rds_instance_name) # rds db to use
      rds_instance_name="${2-}"
      shift
      ;;
    --secret_name) # secret to use
      secret_name="${2-}"
      shift
      ;;
    --subnet_name) # subnet to use
      subnet_name="${2-}"
      shift
      ;;
    --cluster_name) # cluster to use
      cluster_name="${2-}"
      shift
      ;;
    --db_name) # db_name to use
      db_name="${2-}"
      shift
      ;;
    --s3_prefix)
      s3_prefix="${2-}"
      shift
      ;;
    --file_name)
      file_name="${2-}"
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

# function to set terminal color
set_color() {
  case $1 in
  red) color='\033[0;31m' ;;
  green) color='\033[0;32m' ;;
  yellow) color='\033[0;33m' ;;
  blue) color='\033[0;34m' ;;
  purple) color='\033[0;35m' ;;
  cyan) color='\033[0;36m' ;;
  white) color='\033[0;37m' ;;
  *) color='\033[0m' ;;
  esac
  echo -e "$color"
}


# function to test if var is set, if true (not set) else (set)
test_var_is_not_set() {
  if [ -z "$2" ]
  then
    printf "$(set_color red)$1 not set $(set_color) \n\n"
    return 0
  else
    echo "$1 set"
    return 1
  fi
}

# function to prompt user to select from prompt $1 is list of items, $2 is prompt text
select_item() {
  local text=$(printf "$(set_color yellow) $2: $(set_color)"$' \n\n')
  PS3=$text
  select selected_item in $1
  do
    echo $selected_item
    break
  done
}

# function to prompt user to enter item, $1 is prompt text
prompt_item() {
  read -p "$1" item
  echo $item
}

get_region() { #AWS_REGION needs to be set for container to work
echo "getting region"
  if test_var_is_not_set s3_bucket_region $s3_bucket_region
  then
    AWS_REGION=$(prompt_item "Please type the region to be used:  ")
  else
    AWS_REGION=$s3_bucket_region
  fi
}

get_rds_database() {
  echo "getting rds database"
  if test_var_is_not_set rds_instance_name $rds_instance_name
  then
    rds_instances_names=$(aws $profile $region rds describe-db-instances | jq -r '.DBInstances[].DBInstanceIdentifier')
    rds_instance_name=$(select_item "$rds_instances_names" "Please select the rds instance to be used")
  fi
  rds_instance=$(aws $profile $region rds describe-db-instances --db-instance-identifier $rds_instance_name)
  rds_instance_vpc=$(echo $rds_instance | jq -r '.DBInstances[].DBSubnetGroup.VpcId')
  rds_instance_endpoint=$(echo $rds_instance | jq -r '.DBInstances[].Endpoint.Address')
  rds_instance_endpoint_port=$(echo $rds_instance | jq -r '.DBInstances[].Endpoint.Port')
  if test_var_is_not_set db_name $db_name
  then
    db_name=$(prompt_item "Please type the db name to be used:  ")
  fi
}

get_secret() {
  echo "getting secret"
  if test_var_is_not_set secret_name $secret_name
  then
    secrets_names=$(aws $profile $region secretsmanager list-secrets | jq -r '.SecretList[].Name')
    secret_name=$(select_item "$secrets_names" "Please select the secret to be used to connect to the database")
  fi
  secret_arn=$(aws $profile $region secretsmanager describe-secret --secret-id $secret_name | jq -r '.ARN')
}

get_subnet() {
  echo "getting subnet"
  if test_var_is_not_set subnet_name $subnet_name
  then
    subnets_names=subnet_names=$(aws $profile $region ec2 describe-subnets --filters "Name=vpc-id,Values=$rds_instance_vpc" | jq -r '.Subnets[].Tags[] | select(.Key == "Name") | .Value')
    subnet_name=$(select_item "$subnets_names" "Please select the subnet to be used by the fargate container")
  fi
  subnet_id=$(aws $profile $region ec2 describe-subnets --filters "Name=tag:Name,Values=$subnet_name" | jq -r '.Subnets[].SubnetId')
}

get_cluster() {
  echo "getting cluster"
  #echo $cluster_name
  clusters=$(aws $profile $region ecs list-clusters | jq -r '.clusterArns[]')
  if test_var_is_not_set cluster $cluster_name
  then
    clusters_names=$(aws  $profile $region ecs describe-clusters --clusters $clusters --include TAGS | jq -r '.clusters[].tags[] | select(.key=="Name") | .value')
    cluster_name=$(select_item "$clusters_names" "Please select the cluster to be used by the fargate container")
  fi
  cluster=$(aws $profile $region ecs describe-clusters --clusters $clusters --include TAGS | jq -r '.clusters[] | select(.tags[].value=="'$cluster_name'") | .clusterArn')
  #echo $cluster is cluster
}

get_s3_bucket() {
  echo "getting s3 bucket"
  if test_var_is_not_set s3_bucket $s3_bucket
  then
    s3_buckets=$(aws $profile $region s3api list-buckets | jq -r '.Buckets[].Name')
    s3_bucket=$(select_item "$s3_buckets" "Please select the bucket to be used to store the dump")
  fi

  if test_var_is_not_set s3_prefix $s3_prefix
  then
    s3_prefix=$(prompt_item "Please type the prefix to be used to store the dump:  ")
  fi

  if test_var_is_not_set file_name $file_name
  then
    file_name=$(prompt_item "Please type the file name to be used to store the dump:  ")
  fi
}

get_log_group() {
  echo "getting log group"
  log_group_name="/aws/ecs/dump-mysql-db"
  log_group=$(aws $profile $region logs describe-log-groups --log-group-name-prefix $log_group_name --output text)
  if [ -z "$log_group" ]
  then
    aws $profile $region logs create-log-group --log-group-name $log_group_name
    aws $profile $region logs put-retention-policy --log-group-name $log_group_name --retention-in-days 5
  fi
}

get_security_group() {
  echo "getting security group"
  security_group_name="dump-mysql-db"
  security_group=$(aws $profile $region ec2 describe-security-groups --filters "Name=group-name,Values=$security_group_name" --output text)
  if [ -z "$security_group" ]
  then
    security_group=$(aws $profile $region ec2 create-security-group --group-name $security_group_name --description "dump-mysql-db" --vpc-id $rds_instance_vpc)
    security_group_id=$(echo $security_group | jq -r '.SecurityGroups[0].GroupId')
  else
    echo "security group $security_group_name already exists"
    security_group_id=$(aws $profile $region ec2 describe-security-groups --filters "Name=group-name,Values=$security_group_name" | jq -r '.SecurityGroups[0].GroupId')
  fi
}

get_iam_role () {
echo "getting iam role"
cat << EOF > dump-mysql-db-task-role-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

task_role=$(aws $profile $region iam get-role --role-name dump-mysql-db-task-role --query 'Role.Arn' --output text)
if [ -z "$task_role" ]
then
  task_role=$(aws $profile $region iam create-role --role-name dump-mysql-db-task-role --assume-role-policy-document file://dump-mysql-db-task-role-trust-policy.json | jq -r '.Role.Arn')
fi

#TODO restrict these permissions to the minimum needed
aws $profile $region iam attach-role-policy --role-name dump-mysql-db-task-role --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws $profile $region iam attach-role-policy --role-name dump-mysql-db-task-role --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
aws $profile $region iam attach-role-policy --role-name dump-mysql-db-task-role --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws $profile $region iam attach-role-policy --role-name dump-mysql-db-task-role --policy-arn arn:aws:iam::aws:policy/AWSKeyManagementServicePowerUser
aws $profile $region iam attach-role-policy --role-name dump-mysql-db-task-role --policy-arn arn:aws:iam::aws:policy/AmazonRDSFullAccess
aws $profile $region iam attach-role-policy --role-name dump-mysql-db-task-role --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
aws $profile $region iam attach-role-policy --role-name dump-mysql-db-task-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMFullAccess


}

get_task_definition() {
echo "Creating task definition"

cat << EOF > dump-mysql-db-task-def.json
{
  "family": "dump-mysql-db-task-def",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "dump-mysql-db-container",
      "image": "greensmith/rds-import-export:latest",
      "essential": true,
      "linuxParameters": {
          "initProcessEnabled": true
      },
      "environment": [
        {
          "name":"MODE",
          "value": "export"
        },
        {
          "name":"DB_TYPE",
          "value": "mysql"
        },
        {
          "name":"SOURCE_DB_HOST",
          "value": "$rds_instance_endpoint"
        },
        {
          "name":"SOURCE_DB_NAME",
          "value": "$db_name"
        },
        {
          "name": "SOURCE_DB_PORT",
          "value": "$rds_instance_endpoint_port"
        },
        {
          "name":"TARGET_DB_HOST",
          "value": "$rds_instance_endpoint"
        },
        {
          "name":"TARGET_DB_NAME",
          "value": "$db_name"
        },
        {
          "name": "TARGET_DB_PORT",
          "value": "$rds_instance_endpoint_port"
        },
        {
          "name": "S3_BUCKET",
          "value": "$s3_bucket"
        },
        {
          "name":"FILE_NAME",
          "value": "$file_name"
        },
        {
          "name": "S3_PREFIX",
          "value": "$s3_prefix"
        },
        {
          "name": "AWS_REGION",
          "value": "$AWS_REGION"
        }
      ],
      "secrets":[
        {
          "name": "SOURCE_DB_USER",
          "valueFrom": "$secret_arn:username::"
        },
        {
          "name": "SOURCE_DB_PASSWORD",
          "valueFrom": "$secret_arn:password::"
        },
        {
          "name": "TARGET_DB_USER",
          "valueFrom": "$secret_arn:username::"
        },
        {
          "name": "TARGET_DB_PASSWORD",
          "valueFrom": "$secret_arn:password::"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/aws/ecs/dump-mysql-db",
          "awslogs-region": "$AWS_REGION",
          "awslogs-stream-prefix": "dump-mysql-db"
        }
      }
    }
  ],
  "requiresCompatibilities": [
    "FARGATE"
  ],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$task_role",
  "taskRoleArn": "$task_role"
}
EOF

task_def=$(aws $profile $region ecs register-task-definition --cli-input-json file://dump-mysql-db-task-def.json | jq -r '.taskDefinition.taskDefinitionArn')

}

get_task() {
  echo "Running task $cluster $task_def $subnet_id $security_group_id"
  task=$(aws $profile $region  ecs run-task --cluster $cluster --launch-type FARGATE --task-definition $task_def --enable-execute-command --network-configuration "awsvpcConfiguration={subnets=[$subnet_id],securityGroups=[$security_group_id],assignPublicIp=DISABLED}")
  #get task id
  task_arn=$(echo $task | jq -r '.tasks[0].taskArn')
  echo "Task id: $task_arn"
  #task_arn=$(echo $task | jq -r '.tasks[].taskArn')
  #task_id=$(echo $task_arn | cut -d "/" -f 2)
}

get_task_complete() {
  # do while task status is not STOPPED
  task_status=$(aws $profile $region ecs describe-tasks --cluster $cluster --tasks $task_arn | jq -r '.tasks[0].lastStatus')
  while [ "$task_status" != "STOPPED" ]
  do
    echo "waiting for task to complete"
    echo $task_status
    sleep 5
    task_status=$(aws $profile $region ecs describe-tasks --cluster $cluster --tasks $task_arn | jq -r '.tasks[0].lastStatus')
  done
}

get_file_from_s3(){
  echo "Getting file from s3"
  aws $profile $region s3 cp s3://$s3_bucket/$s3_prefix$file_name .
}

get_region
get_rds_database
get_secret
get_subnet
get_cluster
get_s3_bucket
get_log_group
get_security_group
get_iam_role
get_task_definition
get_task
get_task_complete
get_file_from_s3




# task=$(aws $profile $region  ecs run-task --cluster $cluster --launch-type FARGATE --task-definition $task_def --enable-execute-command --network-configuration "awsvpcConfiguration={subnets=[$subnet_id],securityGroups=[$security_group_id],assignPublicIp=DISABLED}")
# #task id has started
# task_id=$(echo $task | jq -r '.tasks[].taskArn')
# echo "task id is: "
# echo "${task_id}"


# # # wait for task to complete
# # echo "waiting for task to complete"
# # aws $profile $region ecs wait tasks-stopped --cluster $cluster --tasks $task_id



# # # delete dump-mysql-db-task-role-trust-policy.json
# # rm dump-mysql-db-task-role-trust-policy.json

# # # delete dump-mysql-db-task-def.json
# # rm dump-mysql-db-task-def.json

# # # delete dump-mysql-db-task-role
# # aws $profile $region iam delete-role --role-name dump-mysql-db-task-role

# # # deregister and delete task definition
# # aws $profile $region ecs deregister-task-definition --task-definition $task_def

