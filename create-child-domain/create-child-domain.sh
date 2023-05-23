#!/usr/bin/env bash

_help() {
  cat << EOF
    $(basename "${BASH_SOURCE[0]}") [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]

    A helper script to create a child subdomain in Route53 and populate an NS record in the parent domain.

    Options:

    -h, --help      Print this help
    -p, --profile    the aws profile where the child domain is to be created (if no profile specified uses default)
    -pp, --parent_profile    the aws profile where the parent domain is located (if no profile specified uses default)
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
    -pp | --parent_profile) # aws profile
      parent_profile="--parent_profile ${2-}"
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



# get user to enter the domain names

read -p 'Please type the parent domain name ' parent_domain_name

read -p 'Please type the sub domain name ' sub_domain_name

child_domain_name=$sub_domain_name.$parent_domain_name

echo "The parent domain name is $parent_domain_name"
echo "The sub domain name is $sub_domain_name"
echo "The full domain name is $child_domain_name"
read -p "is this correct? (y/n) " -n 1 -r


# create the child hosted zone
# profile is child domain profile

aws $profile $region route53 create-hosted-zone --name $child_domain_name --caller-reference $(date +%s)

# get the zone id of the child hosted zone

child_zone_id=$(aws $profile $region route53 list-hosted-zones --query "HostedZones[?Name==\`$child_domain_name.\`].Id" --output text | cut -d'/' -f3)
echo "The child zone id is $child_zone_id"

# get the zone id of the parent hosted zone
# profile is parent domain profile
parent_zone_id=$(aws $parent_profile $region route53 list-hosted-zones --query "HostedZones[?Name==\`$parent_domain_name.\`].Id" --output text | cut -d'/' -f3)
echo "The parent zone id is $parent_zone_id"

# get the name servers of the child hosted zone
child_name_servers=$(aws $profile $region route53 get-hosted-zone --id $child_zone_id --query DelegationSet.NameServers)

ns_record_1=$(echo $child_name_servers | jq -r '.[0]')
ns_record_2=$(echo $child_name_servers | jq -r '.[1]')
ns_record_3=$(echo $child_name_servers | jq -r '.[2]')
ns_record_4=$(echo $child_name_servers | jq -r '.[3]')

# create NS record in the parent domain

change=$(cat <<EOF > change-resource-record-sets.json
  {
    "Comment": "Create an NS record pointing to the $child_domain_name zone",
    "Changes": [
        {
        "Action": "CREATE",
        "ResourceRecordSet": {
            "Name": "$child_domain_name",
            "Type": "NS",
            "TTL": 300,
            "ResourceRecords": [
                    {
                        "Value": "$ns_record_1"
                    },
                    {
                        "Value": "$ns_record_2"
                    },
                    {
                        "Value": "$ns_record_3"
                    },
                    {
                        "Value": "$ns_record_4"
                    }
                ]
            }
        }
    ]
    }
EOF
)

# change record set in parent domain
change_request_id=$(aws $parent_profile $region route53 change-resource-record-sets \
    --hosted-zone-id $parent_zone_id \
    --change-batch file://change-resource-record-sets.json | jq -r '.ChangeInfo.Id')

# wait for change to complete
aws $parent_profile $region route53 wait resource-record-sets-changed --id $change_request_id

# delete the change-resource-record-sets.json file
rm change-resource-record-sets.json

