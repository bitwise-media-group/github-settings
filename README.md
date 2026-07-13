# github-settings

Configuration-as-code for the **bitwise-media-group** GitHub organisation. Two POSIX shell scripts export the live
GitHub configuration to JSON snapshots in this repo and import those snapshots back onto the org and its repositories,
so branch policies, rulesets, labels, and general settings are version-controlled and reproducible rather than clicked
into the web UI.

- **`repo-config.sh`** — one repository's rulesets, labels, Pages source, and settings.
- **`org-config.sh`** — the organisation's rulesets and settings, plus fan-out commands that push a snapshot (labels,
  full config, workflows) across every repo in the org.

Everything is **mirror-synced**: importing makes GitHub match the files on disk, creating and updating what has a file
and deleting what doesn't. Read [Applying changes](#applying-changes) before running an import — a stray empty directory
can mean "delete them all".

## Contents

- [Requirements](#requirements)
- [Repository layout](#repository-layout)
- [Scripts](#scripts)
  - [`repo-config.sh`](#repo-configsh)
  - [`org-config.sh`](#org-configsh)
  - [Environment variables](#environment-variables)
- [Branch & tag policies](#branch--tag-policies)
- [Overriding a policy](#overriding-a-policy)
- [Applying changes](#applying-changes)

## Requirements

- [`gh`](https://cli.github.com/) — authenticated, and with the right scope for the task:
  - repo commands need **admin** on the repository.
  - org commands (rulesets, settings, the `*-sync` fan-outs) need **organisation owner**.
  - `workflows-sync` additionally needs the token's **`workflow`** scope (`gh auth refresh -s workflow`) to write under
    `.github/workflows/`, and **`project`** scope to link the shared board.

  Switch accounts with `gh auth switch` if the active one lacks access.

- [`jq`](https://jqlang.github.io/jq/).

The scripts shell out to `gh` at `/opt/homebrew/bin/gh` (`org-config.sh`) or via `$PATH` (`repo-config.sh`); adjust the
`gh=` line if yours lives elsewhere.

## Repository layout

```text
org-config.sh                 org-level export/import + org-wide sync commands
repo-config.sh                per-repo export/import

org-config/                   snapshot org-config.sh reads/writes (the "org" default dir)
  settings.json                 org general settings (member privileges, new-repo defaults, commit signoff)
  rulesets/*.json               one file per org-level ruleset (the branch/tag/repo policies)

repo-config/                  snapshot repo-config.sh reads/writes, and the source the
  settings.json                 org-wide *-sync commands fan out (the "repo" default dir)
  labels.json                   canonical label set (a single array)
  pages.json                    GitHub Pages build source
  rulesets/                     repo-level rulesets (empty here — all policy is org-level)
  workflows/add-to-project.yaml canonical workflow workflows-sync pushes into every repo

.github/                      this repo's own CI (release-please, CodeQL, /merge flow, …)
release-please-config.json    release automation config
```

Note the two default directories: `org-config.sh` defaults to `org-config/` for `export`/`import`, and to `repo-config/`
for the `*-sync` commands (which fan a _repo_ snapshot out across the org). `repo-config.sh` defaults to `repo-config/`.

## Scripts

Both scripts are `export`/`import` pairs. `export` pulls the live GitHub state down into JSON; `import` pushes the JSON
back up. The org script adds fan-out subcommands on top.

### `repo-config.sh`

```sh
./repo-config.sh export <repo> [dir]   # dump config  -> dir (default: ./repo-config)
./repo-config.sh import <repo> [dir]   # apply config <- dir
```

`<repo>` is the bare repository name; the org is always `bitwise-media-group`. Use it to snapshot this repo, template a
new one, or recreate a repo's configuration.

**Covers:** repository-level rulesets (org rulesets that merely apply to the repo are ignored — manage those with
`org-config.sh`), labels, the Pages build source, and general settings (features, pull-request/merge options, commit
templates, signoff).

**Excluded:** identity (name, description, homepage), `default_branch` (the target may not have the branch yet), and
anything server-managed.

**Mirror semantics:** rulesets and `labels.json` sync both ways — import updates/creates what's listed and deletes what
isn't; a missing file/dir is left alone, an empty one (`[]` for labels, no `*.json` for rulesets) means "remove them
all". `pages.json` is applied but never used to _disable_ Pages.

### `org-config.sh`

```sh
./org-config.sh export <org> [dir]                         # dump org config  -> dir (default: ./org-config)
./org-config.sh import <org> [dir]                         # apply org config <- dir
./org-config.sh labels-sync    [--public|--private] <org> [dir]   # fan labels.json out to every repo
./org-config.sh sync           [--public|--private] <org> [dir]   # run the full repo-config import on every repo
./org-config.sh workflows-sync [--public|--private] <org> [dir]   # fan workflows/*.yaml out + link the shared project
./org-config.sh teams-sync     [--public|--private] <org>         # grant a team a permission on every repo
```

`<org>` defaults to `bitwise-media-group`. The `--public` / `--private` flags limit the `*-sync` commands to repos of
that visibility. The sync commands read a _repo_ snapshot dir (default `repo-config/`).

- **`export` / `import`** — the org's own general settings (member privileges, new-repo security defaults,
  `web_commit_signoff_required`) and org-level rulesets. Rulesets mirror the same way `repo-config.sh` does.
  Enterprise-inherited rulesets are ignored both ways.
- **`labels-sync`** — applies `<dir>/labels.json` to every non-archived repo with the same upsert-and-delete mirror
  logic. **Destructive:** a label absent from the file is deleted from each repo (and from its issues/PRs). Set
  `KEEP_EXTRA=1` to only add/update.
- **`sync`** — runs the full `repo-config.sh import` (settings, rulesets, labels) against every non-archived repo.
- **`workflows-sync`** — commits each `<dir>/workflows/*.yaml` into `.github/workflows/` of every repo via the Contents
  API (upsert only, never deletes), then links the shared Roadmap project (`PROJECT_NUMBER`, default 1) onto each repo
  and backfills its existing issues (`ISSUE_STATE`, default `open`) into the board. This is how the `add-to-project`
  caller is wired into every repo.
- **`teams-sync`** — grants one org team (`TEAM`, default `bitwise-maintainers`) a single permission (`TEAM_PERMISSION`,
  default `maintain`) on every non-archived repo. Additive and idempotent; never removes access.

Per-repo failures in the `*-sync` commands are reported but don't abort the run.

### Environment variables

| Variable          | Applies to       | Effect                                                                                                                                     |
| ----------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `STRIP_BYPASS=1`  | both, `export`   | Drop each ruleset's `bypass_actors` on export — use when the bypass actors (teams, apps, custom roles) won't exist in the target org/repo. |
| `KEEP_EXTRA=1`    | `labels-sync`    | Add/update labels but never delete ones a repo has that aren't in `labels.json`.                                                           |
| `PROJECT_NUMBER`  | `workflows-sync` | Org project to link + backfill into (default `1`, the Roadmap board). `0` skips all project work and only fans the workflow files out.     |
| `ISSUE_STATE`     | `workflows-sync` | Which existing issues to backfill: `open` (default), `closed`, `all`, or `none` to skip the backfill.                                      |
| `TEAM`            | `teams-sync`     | Org team slug to grant (default `bitwise-maintainers`).                                                                                    |
| `TEAM_PERMISSION` | `teams-sync`     | `pull` \| `triage` \| `push` \| `maintain` \| `admin`, or a custom role name (default `maintain`).                                         |

## Branch & tag policies

All branch, tag, and repository policies are **organisation rulesets** (in `org-config/rulesets/`), applied by
`org-config.sh import`. This repo holds no repo-level rulesets — `repo-config/rulesets/` is empty. Each ruleset targets
repos by the system `visibility` property, and the branch rulesets scope to the **protected branches**:
`~DEFAULT_BRANCH` (`main`) and `refs/heads/releases/*`.

| Ruleset                            | Target                                                                       | What it enforces                                                                                                                                                                                                                           |
| ---------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **public-pull-request-required**   | protected branches                                                           | Every change goes through a PR: 1 approving review, **code-owner review required** (see `.github/CODEOWNERS`), stale reviews dismissed on push, last-push approval, all review threads resolved; rebase is the only allowed merge method.  |
| **public-release-branch-security** | protected branches                                                           | Blocks branch deletion and force-pushes (`non_fast_forward`), requires **linear history** and **signed commits** (`required_signatures`).                                                                                                  |
| **public-code-quality**            | protected branches                                                           | Requires **CodeQL** code scanning to pass — security alerts gated at `high_or_higher`, other alerts at `errors`. Public repos only.                                                                                                        |
| **public-fork-only**               | all branches _except_ `main`, `release-please--*`, `dependabot/**`, `bot/**` | Blocks creating or updating any other branch directly in the repo, enforcing the **fork-and-PR** model — contributors push to their own fork, not a branch in the repo. Automation branches (release-please, Dependabot, bots) are exempt. |
| **public-version-tags-only**       | all tags _except_ `v*` and `*--v*`                                           | Blocks creating any tag that isn't a version tag.                                                                                                                                                                                          |
| **public-immutable-tags**          | version tags (`vX.Y.Z`, `*--vX.Y.Z`)                                         | Freezes release tags: no deletion, no update, no force-push; linear history required.                                                                                                                                                      |
| **restrict-transfers**             | the repository object (all repos)                                            | Blocks transferring a repository out of the org.                                                                                                                                                                                           |

Because `public-pull-request-required` reserves the merge to automation, day-to-day merges happen through the org's
**"FF Merge" GitHub App**: a maintainer comments `/merge` (or arms `/auto-merge`) and the App fast-forwards `main`,
preserving each commit's signature so `required_signatures` still holds. See `.github/workflows/merge.yaml`.

## Overriding a policy

There are four escape hatches, in rough order of how routine they are. Which rulesets honour which override:

| Override                        | code-quality | pull-request-required | release-branch-security | fork-only | version-tags-only | immutable-tags | restrict-transfers |
| ------------------------------- | :----------: | :-------------------: | :---------------------: | :-------: | :---------------: | :------------: | :----------------: |
| `bypass-policies` repo property |      ✅      |          ✅           |           ✅            |     —     |         —         |       —        |         —          |
| Organisation admin              |      ✅      |          ✅           |           ✅            |     —     |         —         |       —        |         ✅         |
| "FF Merge" App (Integration)    |      ✅      |          ✅           |            —            |     —     |         —         |       —        |         —          |
| Allowed branch/tag prefix       |      —       |           —           |            —            |    ✅     |        ✅         |       —        |         —          |

**1. The `bypass-policies` custom repository property.** Set the org custom property `bypass-policies` to `true` on a
repo and it is excluded from the three protected-branch rulesets that carry the exclusion — `public-code-quality`,
`public-pull-request-required`, and `public-release-branch-security`. This is the intended per-repo opt-out (e.g. a
scratch or mirror repo). It does **not** relax `fork-only`, the tag rulesets, or `restrict-transfers`. Set it under
**Org → Settings → Repository → Custom properties**, or via the API.

**2. Organisation-admin bypass.** Org admins are listed as an `always` bypass actor on `public-code-quality`,
`public-pull-request-required`, `public-release-branch-security`, and `restrict-transfers`, so an owner can push past
those when genuinely necessary. The tag rulesets and `fork-only` have **no** admin bypass — even an owner can't
force-push a release tag or create an off-model branch.

**3. Automation bypass ("FF Merge" App).** The FF Merge App (`Integration` bypass actor) can bypass
`public-code-quality` and `public-pull-request-required`; that's what lets the `/merge` fast-forward move `main` without
tripping the review/code-scanning gates it already verified out-of-band. Nothing to configure per-repo — it's part of
the shared merge flow.

**4. Work within the allowed prefixes.** `fork-only` and `version-tags-only` aren't "bypassed" so much as scoped:
pushing a branch named `release-please--…`, `dependabot/…`, or `bot/…`, or creating a `vX.Y.Z` tag, is already
permitted. That's how the release and Dependabot automation operate directly in the repo.

**5. Change the policy itself.** The durable "override" is to edit the ruleset JSON in `org-config/rulesets/` and re-run
`./org-config.sh import` — that's the whole point of keeping these under version control. To move a ruleset's config
between orgs/repos where the bypass actors don't exist, export with `STRIP_BYPASS=1` so the actor IDs don't come along.

## Applying changes

Edit the JSON snapshot, then import it:

```sh
# One repository
./repo-config.sh export github-settings          # capture live state -> repo-config/
#   …edit repo-config/… , review the diff, then:
./repo-config.sh import github-settings           # push it back up

# The organisation (rulesets + settings)
./org-config.sh export bitwise-media-group        # -> org-config/
./org-config.sh import bitwise-media-group

# Fan a change across every repo
./org-config.sh labels-sync bitwise-media-group           # labels only
./org-config.sh sync bitwise-media-group                  # full repo-config import everywhere
./org-config.sh workflows-sync bitwise-media-group        # managed workflows + project link
```

**Import is a mirror, not a merge — review the git diff first.** For rulesets and labels, import _deletes_ anything on
GitHub that has no matching file/entry; an empty `labels.json` (`[]`) or an empty `rulesets/` dir is read as "remove
them all". A _missing_ file or directory, by contrast, is left untouched. When in doubt, `export` into a scratch dir and
diff before importing.
