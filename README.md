# codex-installer

> Because even a scrappy little startup like OpenAI sometimes needs a hand shipping a proper native installer.

A single-script installer and self-updating wrapper for the [OpenAI Codex CLI](https://github.com/openai/codex) on Linux (x86_64 & aarch64, glibc & musl).

## Quick Install

```sh
curl -fsSL https://raw.githubusercontent.com/welidev/codex-installer/main/codex-installer.sh | sh
```

That's it. One line, zero dependencies beyond `curl`, `jq`, and `tar`.

## What It Does

- **Fetches** the latest Codex CLI release from GitHub
- **Detects** your architecture and libc automatically
- **Installs** the binary to `/usr/local/bin` (falls back to `~/.local/bin` if not writable)
- **Wraps** the real binary so it can check for updates on every run
- **Updates** itself — configurable as automatic, prompted, or never

## Usage

```sh
# Install or update
./codex-installer.sh install [--force] [--yes]

# Uninstall
./codex-installer.sh uninstall [--yes]

# Show help
./codex-installer.sh --help
```

### Options

| Flag | Description |
|------|-------------|
| `--force`, `-f` | Re-install even if already up to date |
| `--yes`, `-y` | Skip confirmation prompts |
| `--help`, `-h` | Show usage information |

## Configuration

After installation a config file is created at `/etc/codex-wrapper/config` (system-wide) or `~/.config/codex-wrapper/config` (per-user). You can also set these via environment variables:

| Variable | Values | Default | Description |
|----------|--------|---------|-------------|
| `INSTALL_DIR` | any path | `/usr/local/bin` | Where to place the binaries |
| `CODEX_UPDATE_MODE` | `auto` \| `prompt` \| `never` | `prompt` | How updates are handled |
| `CODEX_UPDATE_INTERVAL` | `always` \| `<N><unit>` | `24h` | How often to check for updates |

Interval examples: `30m`, `12h`, `7d`, `1w`, `always`.

## Requirements

- Linux (x86_64 or aarch64)
- `curl` or `wget`
- `jq`
- `tar`
- `sudo` (only if installing to a privileged directory)

## License

MIT
