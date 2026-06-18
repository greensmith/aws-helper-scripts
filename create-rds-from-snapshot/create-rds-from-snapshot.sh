#!/usr/bin/env bash

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

# get vpc id with name "lhasa-common-vpc"
vpc_id=$(aws ${profile} ${region} ec2 describe-vpcs --query 'Vpcs[?Tags[?Key==`Name` && Value==`lhasa-common-vpc`]].VpcId' --output text)
echo "VPC ID: $vpc_id"

# get list of db subnet groups
db_subnet_groups=$(aws ${profile} ${region} rds describe-db-subnet-groups --query 'DBSubnetGroups[?VpcId==`'$vpc_id'`].DBSubnetGroupName' --output text)

# present the list of db subnet groups to the user
PS3="Please enter the number of the DB Subnet Group: "$'\n'
select db_subnet_group in ${db_subnet_groups[@]}; do
    export SELECTED_DB_SUBNET_GROUP=$(echo $db_subnet_group | awk '{print $1}' | tr '"' ' ')
    echo "Selected DB Subnet Group: $SELECTED_DB_SUBNET_GROUP"
    break
done

# get list of RDS parameter groups
parameter_groups=$(aws ${profile} ${region} rds describe-db-parameter-groups --query 'DBParameterGroups[].DBParameterGroupName' --output text)

# present the list of parameter groups to the user
PS3="Please enter the number of the Parameter Group: "$'\n'
select parameter_group in ${parameter_groups[@]}; do
    export SELECTED_PARAMETER_GROUP=$(echo $parameter_group | awk '{print $1}' | tr '"' ' ')
    echo "Selected Parameter Group: $SELECTED_PARAMETER_GROUP"
    break
done

# connect to AWS and get list of latest RDS manual snapshots
snapshots=$(aws ${profile} ${region} rds describe-db-snapshots --snapshot-type manual --query 'reverse(sort_by(DBSnapshots, &SnapshotCreateTime))[].{DBSnapshotIdentifier: DBSnapshotIdentifier, SnapshotCreateTime: SnapshotCreateTime}' --output text)

# present the list of snapshots to the user
PS3="Please enter the number of the snapshot: "$'\n'
select snapshot in ${snapshots[@]}; do
    export SELECTED_SNAPSHOT=$(echo $snapshot | awk '{print $1}' | awk -F/ '{print $NF}' | tr '"' ' ')
    snapshot_date=$(echo $snapshot | awk '{print $2}')
    echo "Selected snapshot: $SELECTED_SNAPSHOT (Created on: $snapshot_date)"
    break
done

# output the selected snapshot's ID to a variable
echo "Selected snapshot ID: $SELECTED_SNAPSHOT"

# get list of security group names in the selected VPC
security_groups=$(aws ${profile} ${region} ec2 describe-security-groups --query 'SecurityGroups[?VpcId==`'$vpc_id'`].GroupName' --output text)

# present the list of security groups to the user
PS3="Please enter the number of the Security Group: "$'\n'
select security_group in ${security_groups[@]}; do
    export SELECTED_SECURITY_GROUP=$(echo $security_group | awk '{print $1}' | tr '"' ' ')
    echo "Selected Security Group: $SELECTED_SECURITY_GROUP"
    break
done

# get security group id from the selected security group name
security_group_id=$(aws ${profile} ${region} ec2 describe-security-groups --query 'SecurityGroups[?GroupName==`'$SELECTED_SECURITY_GROUP'`].GroupId' --output text)

# restore single rds mysql instance using the selected snapshSELECTED_SECURITY_GROUP and selected parameter group

aws ${profile} ${region} rds restore-db-instance-from-db-snapshot --db-instance-identifier mayrollback --db-snapshot-identifier $SELECTED_SNAPSHOT --db-instance-class db.t3.micro --engine mysql --db-subnet-group-name $SELECTED_DB_SUBNET_GROUP --db-parameter-group-name $SELECTED_PARAMETER_GROUP --no-publicly-accessible --no-multi-az --no-auto-minor-version-upgrade --no-copy-tags-to-snapshot --vpc-security-group-ids $security_group_id --output text