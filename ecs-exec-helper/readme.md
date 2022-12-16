# Ecs Exec Helper

Purpose of this script is to make it easier to enter an interactive shell/run commands on AWS ECS containers

## assumptions and pre-requisties

the assumption is that the containers you are trying to connect to have already been configured to use esc exec command

the following AWS documentation describes how to enable and configure this https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html

we also are assuming that your aws credentials are configured correctly to access the nessecery services.

## ecs execute-command

The properties requried to execute the ecs execute-commmand are

- cluster: the name of the cluster on which your container is running
- task: the task id that has your container
- container: the name of the container inside the task that you wish to connect to
- command: the command to run

gathering this information can be fiddly as you need to copy values from multiple api calls or pages in the console.

## what this script does

this script will

- connect to the aws account using the default profile or the profile provided
- fetch back a list of clusters for you to choose from
- fetch back a list of tasks running on that cluster for you to choose from
- fetch back a list of containers inside that task for you to choose from
- prompt for the command to execute (interactively)


## command

```bash
./ecs-exec-helper.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
```

e.g.

```bash
./ecs-exec-helper.sh --profile MyDevAccount --region eu-west-1
```