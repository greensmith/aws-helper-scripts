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


# get the subnet names of vpc subnets
subnets=$(aws ${profile} ${region} ec2 describe-subnets --query 'Subnets[?VpcId==`'$vpc_id'`].Tags[?Key==`Name`].Value' --output text)

# present the list of subnets to the user
PS3="Please enter the number of the Subnet: "$'\n'
select subnet in ${subnets[@]}; do
    export SELECTED_SUBNET=$(echo $subnet | awk '{print $1}' | tr '"' ' ')
    echo "Selected Subnet: $SELECTED_SUBNET"
    break
done

# get subnet id from the selected subnet name
subnet_id=$(aws ${profile} ${region} ec2 describe-subnets --query 'Subnets[?Tags[?Key==`Name` && Value==`'$SELECTED_SUBNET'`]].SubnetId' --output text)


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


# get list of IAM instance profiles
instance_profiles=$(aws ${profile} ${region} iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output text)

# present the list of instance profiles to the user
PS3="Please enter the number of the Instance Profile: "$'\n'
select instance_profile in ${instance_profiles[@]}; do
    export SELECTED_INSTANCE_PROFILE=$(echo $instance_profile | awk '{print $1}' | tr '"' ' ')
    echo "Selected Instance Profile: $SELECTED_INSTANCE_PROFILE"
    break
done

# get the latest Amazon Linux 2 AMI ID
ami_id=$(aws ${profile} ${region} ec2 describe-images --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-2.0.????????.?-x86_64-gp2" "Name=state,Values=available" --query 'reverse(sort_by(Images, &CreationDate))[].ImageId' --output text)

# create the ec2 instance
instance_id=$(aws ${profile} ${region} ec2 run-instances --image-id $ami_id --count 1 --instance-type t2.micro  --security-group-ids $security_group_id --subnet-id $subnet_id --iam-instance-profile Name=$SELECTED_INSTANCE_PROFILE --query 'Instances[0].InstanceId' --output text)

