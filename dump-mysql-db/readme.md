# Dump / Restore MYSQL DB

Purpose of this script is to make it easier to dump / restore a mysql RDS db

## assumptions and pre-requisties


we also are assuming that your aws credentials are configured correctly to access the nessecery services.


## what this script does

this script will

-


## command

```bash
./dump-mysql-db.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
```

```bash
./restore-mysql-db.sh [-h or ---help] [-p or --profile profilename] [-r or --region awsregion]
```

e.g.

```bash
./dump-mysql-db.sh --profile MyDevAccount --region eu-west-1
```

```bash
./restore-mysql-db.sh --profile MyDevAccount --region eu-west-1
```
