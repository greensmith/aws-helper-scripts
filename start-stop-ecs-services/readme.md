# Stop/Start ECS Services

Purpose of these scripts is to make it easier to stop/start all services on an ECS cluster

## assumptions and pre-requisties

the assumption is that you know the cluster/services you are wanting to stop

we also are assuming that your aws credentials are configured correctly to access the nessecery services.

## ecs update-service

The properties used by ecs update-service are

- cluster, the cluster the service is running on
- service, the service we are altering
- desired-count, the count of the service (currently only supports 1 or 0)

## what this script does

this script will

- connect to the aws account using the default profile or the profile provided
- fetch back a list of ECS clusters to choose from
- prompt the user to confirm
- edit the desired count of every service on the cluster


## command

```bash
./stop-ecs-services.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
./start-ecs-services.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
```

e.g.

```bash
./stop-ecs-services.sh --profile MyDevAccount --region eu-west-1
./start-ecs-services.sh --profile MyDevAccount --region eu-west-1
```
