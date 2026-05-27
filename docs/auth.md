# Auth and Permissions Reference

This document covers authentication options for zbuild GitHub Actions workflows and explains when each is appropriate.

## GITHUB_TOKEN

`GITHUB_TOKEN` is an automatically provisioned short-lived token that GitHub creates for every workflow run. It requires no setup and expires when the run ends.

**Default permissions used by zbuild workflows:**

```yaml
permissions:
  contents: read        # checkout the repository
  issues: write         # post pipeline status comments
  pull-requests: write  # open PRs, add review comments
```

**When it is sufficient:**

- Running the pipeline on the same repository that hosts the workflow
- Reading repository contents, posting issue comments, and opening pull requests within that repo
- Standard delivery pipelines that do not trigger workflows in other repositories

`GITHUB_TOKEN` cannot approve its own pull requests (GitHub blocks self-review), trigger `workflow_dispatch` events in other repositories, or access private forks outside the current repository.

## Personal Access Token (PAT)

A PAT is a long-lived token tied to a specific GitHub user account. Use one only when `GITHUB_TOKEN` is insufficient.

**When a PAT is needed:**

- Triggering workflows in a different repository (cross-repo dispatch)
- Accessing private forks that the built-in token cannot reach
- Performing actions that require elevated organization-level permissions

**Required scopes:**

| Scope | Reason |
|-------|--------|
| `repo` | Full read/write access to repositories (includes private repos) |
| `workflow` | Create or update GitHub Actions workflow files |

**Setting up the PAT:**

1. Generate the token at `github.com → Settings → Developer settings → Personal access tokens`.
2. Select the `repo` and `workflow` scopes (and nothing else — least privilege).
3. In the target repository go to `Settings → Secrets and variables → Actions`.
4. Create a new repository secret named `ZBUILD_PAT` and paste the token value.

Reference it in the calling workflow:

```yaml
secrets:
  GITHUB_TOKEN: ${{ secrets.ZBUILD_PAT }}
```

## Workflow Permissions Block

The following block appears in `.github/workflows/zbuild-pipeline.yml` and must be present in any caller workflow that does not override it:

```yaml
permissions:
  contents: read        # git checkout; no write access to tree
  issues: write         # pipeline status updates posted as comments
  pull-requests: write  # PR creation and review comments
```

Explanation of each entry:

- `contents: read` — allows `actions/checkout` to clone the repository. Write access is not granted; the workflow does not push commits directly.
- `issues: write` — allows the pipeline to post progress comments and close issues on completion.
- `pull-requests: write` — allows the pipeline to open pull requests and add review comments.

All other permissions default to `none`, following the principle of least privilege.

## Security Recommendations

- **Least privilege.** Only grant the permissions a workflow actually needs. Do not use `permissions: write-all`.
- **Never hardcode tokens.** All tokens must be stored as GitHub Actions secrets and referenced via `${{ secrets.NAME }}`. A token in source code is a security incident.
- **Prefer `GITHUB_TOKEN` over PATs.** `GITHUB_TOKEN` is scoped to the run and expires automatically. PATs are long-lived and must be rotated regularly.
- **Rotate PATs on a schedule.** Set an expiration date when creating the token. Revoke and regenerate if a repository is compromised.
- **Audit secret access.** Review who has admin access to repository secrets. Anyone with admin access can extract a secret through a workflow.
- **Scope PATs narrowly.** If the workflow only needs to trigger a dispatch event in another repo, use a fine-grained PAT scoped to that repository rather than a classic PAT with broad `repo` access.
