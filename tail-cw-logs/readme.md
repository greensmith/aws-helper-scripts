# Tail CW Logs

Purpose of this script is to make it easier to tail a cloudwatch log stream

## assumptions and pre-requisties

the assumption is that the know the log group/stream you wish to watch.

we also are assuming that your aws credentials are configured correctly to access the nessecery services.

## logs tail

The properties used to execute the logs tail are

- log-group, the selected log group
- log-stream-name-prefix, the provide log stream prefix (optional)
- follow, tells the cli to watch/tail the log
- format, set to short to not print out too much information.


## what this script does

this script will

- connect to the aws account using the default profile or the profile provided
- fetch back a list of log groups to choose from
- prompt the user for a log stream prefix (optional)
- start watching logs from the entire log group, or just the prefixed streams in the terminal.


## command

```bash
./tail-cw-logs.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
```

e.g.

```bash
./tail-cw-logs.sh --profile MyDevAccount --region eu-west-1
```