# EC2 Start Session

Purpose of this script is to make it easier to start an SSM session on a running EC2 instance.

## Assumptions and Prerequisites

- The instances you are trying to connect to have the SSM Agent installed and running, and you have permissions to start SSM sessions.
- Your AWS credentials are configured correctly to access the necessary services.
- Required tools: `aws` CLI v2, `fzf`, `jq`

## What This Script Does

Uses `fzf` for interactive fuzzy selection of:

1. **AWS profile** from `~/.aws/config` (skipped if `--profile` is provided)
2. **EC2 instance** from a list of running instances (with metadata preview)

### Features

- Fuzzy profile selection from `~/.aws/config`
- Instance list with Name tags, instance ID, type, and availability zone
- Preview pane showing network details (private/public IP), instance type, and launch time
- ANSI-coloured entries for readability
- Executes `aws ssm start-session --target <instance-id>`

## Usage

```bash
# Interactive (prompts for everything)
./ec2-start-session.sh

# With a specific profile
./ec2-start-session.sh --profile MyDevAccount

# With region override
./ec2-start-session.sh --region eu-west-1

# Combined
./ec2-start-session.sh -p MyDevAccount -r eu-west-1
```

## Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Print help and exit |
| `-p`, `--profile` | AWS profile to use (bypasses fzf profile selection) |
| `-r`, `--region` | AWS region override |
| `-v`, `--version` | Print version and exit |
