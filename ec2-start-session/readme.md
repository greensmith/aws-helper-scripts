# Ec2 Start Session

Purpose of this script is to make it easier to enter an interactive shell/run commands on AWS EC2 instance

## assumptions and pre-requisties

the assumption is that the instances you are trying to connect to have already been configured with SSM agent and you can start SSM sessions with them.

we also are assuming that your aws credentials are configured correctly to access the nessecery services.

## ssm start-session

The properties requried to execute the ssm start-session  are

- target: an ec2 instance id

## what this script does

this script will

- connect to the aws account using the default profile or the profile provided
- fetch back a list of running ec2 instance names for you to choose from
- fetch back the instance id of the selected instance
- execute ssm start-session --target <instance-id>


## command

```bash
./ec2-start-session.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
```

e.g.

```bash
./ec2-start-session.sh --profile MyDevAccount --region eu-west-1
```
