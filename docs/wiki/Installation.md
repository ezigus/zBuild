# Installation

This page gets zBuild onto your machine. The process takes about five minutes: install a few standard tools, clone the repo, and run one script.

## What you need first

zBuild is a Bash tool, so it needs a few standard command-line utilities. Install them with your package manager:

```bash
# macOS (Homebrew)
brew install bash git jq gh rsync flock coreutils

# Linux (Debian / Ubuntu)
sudo apt install bash git jq gh rsync util-linux
```

**macOS note:** macOS ships with an old version of Bash (3.2) at `/bin/bash`. zBuild requires Bash 5 or later — the `brew install bash` command above installs it at `/usr/local/bin/bash` (Intel) or `/opt/homebrew/bin/bash` (Apple Silicon). The installer will warn you if it finds the wrong version.

## Install zBuild

```bash
git clone https://github.com/ezigus/zBuild ~/code/zBuild
cd ~/code/zBuild
./install.sh
```

The installer copies zBuild into `~/.local/share/zbuild` and puts two short commands — `zbuild` and `zb` — into `~/.local/bin`.

If `~/.local/bin` is not on your `PATH`, add this line to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.) and restart your terminal:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Verify

```bash
zbuild --version          # should print the installed version
zbuild doctor             # checks Bash version, tools, config, and more
```

If `doctor` reports a problem, see [[Troubleshooting]].

## Upgrade

```bash
zbuild upgrade --from ~/code/zBuild   # pulls the latest code, then re-runs install.sh
```

---

Ready? Go to **[[Getting-Started]]** to run your first pipeline.

## Advanced: what the installer does

*Newcomers can skip this section — it covers installer internals you won't need for normal use.*

`install.sh` (specified in ADR-023) is the only supported install mechanism. It:
- copies `scripts/`, `core/`, `plugins/`, and `config/` into `$ZBUILD_HOME` (default `~/.local/share/zbuild`) using `rsync --delete` — so re-running it is safe and idempotent;
- writes `zbuild` and `zb` shim scripts into `$ZBUILD_INSTALL_DIR` (default `~/.local/bin`);
- records the installed git SHA, branch, and timestamp at `$ZBUILD_HOME/version`;
- smoke-tests `zbuild --version` to confirm the shims work.

On macOS, the installer will automatically `brew install` any missing dependencies (`flock`, `coreutils`, `bash`) when Homebrew is present.

**Why `flock`?** zBuild uses `flock` to take atomic leases on work items when using the local-filesystem claim backend, preventing two runs from grabbing the same task simultaneously.

**Why `gtimeout` (from coreutils)?** zBuild wraps AI model calls and test-file execution in timeouts. Without `gtimeout` on macOS those timeouts silently do nothing, so a hung model call or test file would block a run indefinitely.
