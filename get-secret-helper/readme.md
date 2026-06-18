# Get Secret Helper

Purpose of this script is to make it easier to get a secret value from AWS Secrets Manager.

## Assumptions and Prerequisites

- Your AWS credentials are configured correctly to access the necessary services.
- Required tools: `aws` CLI v2, `fzf`, `jq`
- Optional (for clipboard): `xclip`, `xsel`, `pbcopy` (macOS), or `wl-copy` (Wayland)

## What This Script Does

Uses `fzf` for interactive fuzzy selection of:

1. **AWS profile** from `~/.aws/config` (skipped if `--profile` is provided)
2. **Secret** from the secrets list (with metadata preview pane)
3. **JSON key extraction** (if the secret value is JSON, you can select a specific key)

### Features

- Fuzzy profile selection from `~/.aws/config`
- Secret list with Name tags and metadata preview pane
- Formatted JSON output with syntax highlighting
- JSON key extraction — select a specific key to extract its value
- Clipboard copy support (auto-detects clipboard tool)

## Usage

```bash
# Interactive (prompts for everything)
./get-secret-helper.sh

# With a specific profile
./get-secret-helper.sh --profile MyDevAccount

# With region override
./get-secret-helper.sh --region eu-west-1

# Combined
./get-secret-helper.sh -p MyDevAccount -r eu-west-1
```

## Options

| Flag | Description |
|------|-------------|
| `-h`, `--help` | Print help and exit |
| `-p`, `--profile` | AWS profile to use (bypasses fzf profile selection) |
| `-r`, `--region` | AWS region override |
| `-v`, `--version` | Print version and exit |