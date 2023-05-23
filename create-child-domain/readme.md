# Create Child Domain

Purpose of this script is to create a child subdomain in Route53 and populate an NS record in the parent domain.

## assumptions and pre-requisties

the assumption is that the know the domain names and which aws profiles to use

we also are assuming that your aws credentials are configured correctly to access the nessecery services.


## what this script does

this script will

- connect to the aws account using the default profile or the profiles provided
- prompt the user for a parent domain name (e.g. example.com)
- prompt the user for the subdomain (e.g. myapp)
- prompt the user to confirm the details (e.g. myapp.example.com)
- create new hosted zone (e.g. myapp.example.com) in profile
- update the hosted zone in the parent domain (e.g. example.com) with the NS records for suddomain (e.g. myapp.example.com)


## command

```bash
./create-child-domain.sh [-h or ---help] [-p or --profile profilename] [-pp or --parent_profile profilename] [-r or --region awsregion]
```

e.g.

```bash
./create-child-domain.sh  --profile MyDevAccount --parent_profile MyRootAccount --region eu-west-1
```