# Download CW Logs

Purpose of this script is to download todays cloudwatch logs and save them as a log file

## assumptions and pre-requisties

the assumption is that you know the cw logs you'd like to target

we also are assuming that your aws credentials are configured correctly to access the nessecery services.

## logs get-log-events

The properties used to execute the ssm start-session  are

- start-from-head, set to true this starts from oldest log and works down
- start-time, set to midnight of the current day
- log-group-name, log group name specified by user
- log-stream-name, log stream name specified by user

## what this script does

this script will

- connect to the aws account using the default profile or the profile provided
- fetch back a list of log groups to select
- fetch back a list of log streams to select
- execute logs get-log-events and output to log file
- execute logs get-log-events again for every additional nextToken and output to log file



## command

```bash
./download-cw-logs.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
```

e.g.

```bash
./download-cw-logs.sh --profile MyDevAccount --region eu-west-1
```
