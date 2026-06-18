# ECS Exec Helper

Purpose of this script is to make it easier to enter an interactive shell/run commands on AWS ECS containers.

## Assumptions and Prerequisites

- The containers you are trying to connect to have already been configured to use ECS Exec. See the [AWS documentation](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html) for setup instructions.
- Your AWS credentials are configured correctly to access the necessary services.
- Required tools: `aws` CLI v2, `fzf`, `jq`

## What This Script Does

Uses `fzf` for interactive fuzzy selection of:

1. **AWS profile** from `~/.aws/config` (skipped if `--profile` is provided)
2. **Cluster / Service / Task / Container** in a single hierarchical view
3. **Command** to execute (presets + custom input)

### Features

- Fuzzy profile selection from `~/.aws/config`
- Single hierarchical fzf view: Cluster → Service → Task → Container
- ANSI-coloured entries with Name tags
- Preview pane showing task status, start time, image, and health
- Command picker with presets (`/bin/sh`, `/bin/bash`, `/bin/ash`) + custom input

## Usage

```bash
# Interactive (prompts for everything)
./ecs-exec-helper.sh

# With a specific profile
./ecs-exec-helper.sh --profile MyDevAccount

# With region override
./ecs-exec-helper.sh --region eu-west-1

# Combined
./ecs-exec-helper.sh -p MyDevAccount -r eu-west-1
```

## Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Print help and exit |
| `-p`, `--profile` | AWS profile to use (bypasses fzf profile selection) |
| `-r`, `--region` | AWS region override |
| `-v`, `--version` | Print version and exit |