# Installing zBuild

zBuild's installer copies the pipeline runtime into a stable location so that
running pipelines are unaffected by edits, branch switches, or upgrades to the
source clone. See [ADR-023](adr/ADR-023-install-isolation.md) for the design
rationale.

## Quick start

```bash
git clone https://github.com/ezigus/zBuild ~/code/zBuild
cd ~/code/zBuild
./install.sh
```

This:
1. Verifies prerequisites (`bash` >= 5, `git`, `jq`, `gh`, `rsync`).
2. Copies `scripts/`, `core/`, `plugins/`, `config/` into `$ZBUILD_HOME`.
3. Writes `$ZBUILD_HOME/version` capturing the source SHA, branch, and
   install timestamp.
4. Installs a thin shim at `$ZBUILD_INSTALL_DIR/zbuild` (and `zb`) that
   `exec`s `$ZBUILD_HOME/scripts/zbuild`.

## Environment variables

| Variable               | Default                       | Purpose                                            |
| ---------------------- | ----------------------------- | -------------------------------------------------- |
| `ZBUILD_HOME`          | `~/.local/share/zbuild`       | Where the installed pipeline runtime lives.        |
| `ZBUILD_INSTALL_DIR`   | `~/.local/bin`                | Where the `zbuild` / `zb` shim is written.         |

Both can be set in the environment before running `install.sh`.

## Checking the installed version

```bash
zbuild version
# zbuild 0.1.0
#   sha: <40-char SHA>
#   branch: main
#   installed_at: 2026-05-31T12:34:56Z
#   source: /Users/you/code/zBuild
```

When invoked directly from the source clone (`bash scripts/zbuild version`),
the SHA is read from `git rev-parse HEAD` instead of `$ZBUILD_HOME/version`.

## Upgrading

```bash
zbuild upgrade --from ~/code/zBuild
```

`upgrade` runs `git pull --ff-only` in the source clone and then re-execs its
`install.sh`. `--from` is required because `$ZBUILD_HOME` itself has no
`.git/` — zbuild needs to know where your source checkout lives.

## Migrating from a legacy install

If you installed zBuild before ADR-023 shipped, `~/.local/bin/zbuild` is a
symlink into your source clone. Re-running `./install.sh` detects this,
removes the symlink, and writes the new shim. A `migrating: replacing legacy
symlink` notice is printed.

After migration:
- The source clone can change branches freely without affecting running
  pipelines.
- `zbuild version` reports the installed SHA, not the source clone HEAD.

## CI / dev mode

CI workflows invoke `bash scripts/zbuild ...` directly from the checkout and
do not require an install. This path is unchanged by ADR-023.

## What's copied vs. what's not

| Copied to `$ZBUILD_HOME`     | Skipped                                 |
| ---------------------------- | --------------------------------------- |
| `scripts/`                   | `tests/` — only needed for development  |
| `core/`                      | `docs/` — reference, not runtime        |
| `plugins/`                   | `legacy/` — frozen reference            |
| `config/`                    | `.git/` — no version-control needed     |
