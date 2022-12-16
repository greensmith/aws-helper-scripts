#!/usr/bin/env bash

_help() {
  cat << EOF
    $(basename "${BASH_SOURCE[0]}") [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]

    A helper script to select and view aws secrets

    You will be prompted to select a secret
    then the value will be printed

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

secrets=$(aws ${profile} ${region} secretsmanager list-secrets --query "SecretList[*].Name" --output json | tr -d "[]" | tr -d  '[:blank:]' | tr -d '[:space:]' | tr -d '"' | tr "," " ")

PS3="Please select the secret :"$'\n'
select secret in $secrets
do
  # Use the AWS CLI to get the Secret value
  secret_value=$(aws ${profile} ${region} secretsmanager get-secret-value --secret-id $secret)

  # Print the Secret value to the console
  echo "The secret value is: "
  echo "${secret_value}"
  break
done

