# AWS Helper Scripts

A collection of interactive helper scripts for common AWS operations. All scripts use `fzf` for fuzzy selection, `jq` for JSON processing, and provide coloured output with preview panes.

**Common requirements:** `aws` CLI v2, `fzf`, `jq`

---

## ECS Exec Helper

Interactive tool to select and execute commands on ECS Fargate containers.

- Hierarchical fzf view: Cluster → Service → Task → Container (with Name tags)
- Preview pane with task status, image, and health
- Command picker with presets + custom input

```bash
./ecs-exec-helper/ecs-exec-helper.sh
./ecs-exec-helper/ecs-exec-helper.sh --profile MyDevAccount --region eu-west-1
```

---

## EC2 Start Session

Interactive tool to start SSM sessions on running EC2 instances.

- Instance list with Name tags, instance type, and availability zone
- Preview pane with network details and launch time
- Starts `ssm start-session` on the selected instance

```bash
./ec2-start-session/ec2-start-session.sh
./ec2-start-session/ec2-start-session.sh --profile MyDevAccount --region eu-west-1
```

---

## Get Secret Helper

Interactive tool to view AWS Secrets Manager secrets.

- Secret list with Name tags and metadata preview pane
- JSON key extraction — select a specific key from JSON secrets
- Clipboard copy support (auto-detects `xclip`/`xsel`/`pbcopy`/`wl-copy`)

```bash
./get-secret-helper/get-secret-helper.sh
./get-secret-helper/get-secret-helper.sh --profile MyDevAccount --region eu-west-1
```

---

## Fargate Task Monitor

A Fargate task monitor that displays all running tasks in a table and tails CloudWatch logs for the selected container.

- Table view: Container / Task / Service / Cluster with status and Name tags
- Preview pane with container details and log configuration
- Auto-detects CloudWatch log group/stream from task definition
- Live log tailing with configurable history (`--since`)

```bash
./fargate-task-monitor/fargate-task-monitor.sh
./fargate-task-monitor/fargate-task-monitor.sh --profile my-account --since 15
```

---

## Download CW Logs

Purpose of this script is to download today's CloudWatch logs and save them as a log file.

---

## Common Options

All interactive scripts support these flags:

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Print help and exit |
| `-p`, `--profile` | AWS profile to use (bypasses fzf profile selection) |
| `-r`, `--region` | AWS region override |
| `-v`, `--version` | Print version and exit |