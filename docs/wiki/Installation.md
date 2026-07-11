# Installation

## Prerequisites
zBuild needs: `bash` ≥ 5, `git`, `jq`, `gh` (GitHub CLI), `rsync`, `flock`, and `coreutils` (macOS — provides `gtimeout`).

```bash
# macOS
brew install bash git jq gh rsync flock coreutils
# Linux (Debian/Ubuntu)
sudo apt install bash git jq gh rsync util-linux
```

Notes:
- macOS ships Bash 3.2 at `/bin/bash`; zBuild requires Bash 5+ (install via Homebrew).
- `flock` provides atomic label leases for the local-fs claim backend (ADR-005).
- `gtimeout` (from coreutils) bounds model calls and hung test files; without it those timeouts silently no-op.
- On macOS, `./install.sh` will auto-`brew install` any missing `flock` / `coreutils` / `bash` when Homebrew is present.

## Install
```bash
git clone https://github.com/ezigus/zBuild ~/code/zBuild
cd ~/code/zBuild
./install.sh
```

`install.sh` (ADR-023):
- copies the runtime (`scripts/ core/ plugins/ config/`) into **`$ZBUILD_HOME`** (default `~/.local/share/zbuild`) via `rsync --delete` (idempotent),
- writes `zbuild` and `zb` shims into **`$ZBUILD_INSTALL_DIR`** (default `~/.local/bin`),
- records install metadata (SHA/branch/timestamp) at `$ZBUILD_HOME/version`,
- smoke-tests `zbuild --version`.

If `~/.local/bin` isn't on your `PATH`, add it: `export PATH="$HOME/.local/bin:$PATH"`.

## Upgrade
```bash
zbuild upgrade --from ~/code/zBuild   # pulls main, then re-runs install.sh
```

## Verify
```bash
zbuild --version
zbuild doctor        # validates bash>=5, gh, jq, sqlite3, config, etc.
```

See [[Troubleshooting]] if `doctor` reports problems.
