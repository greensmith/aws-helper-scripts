# Get Secret Helper

Purpose of this script is to make it easier to get a secret value from Secrets Manager

## assumptions and pre-requisties

we are assuming that your aws credentials are configured correctly to access the nessecery services.

## what this script does

this script will

- connect to the aws account using the default profile or the profile provided
- fetch back a list of secrets for you to choose from
- print the value of that secret in the terminal

of course, this is not very secure (results are printed in plain text) it would be advisable to find a better solution.

## command

```bash
./get-secret-helper.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
```

e.g.

```bash
./get-secret-helper.sh --profile MyDevAccount --region eu-west-1
```