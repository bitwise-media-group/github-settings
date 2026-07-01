#!/usr/bin/env sh
set -eu

# org-config.sh — export/import a GitHub organisation's rulesets and general
# settings, plus fan repo labels out across the org; the org-level companion to
# repo-config.sh.
#
#   ./org-config.sh export <org> [dir]        # dump config  -> dir (default: ./org-config)
#   ./org-config.sh import <org> [dir]        # apply config <- dir
#   ./org-config.sh labels-sync    [--public|--private] <org> [dir]
#   ./org-config.sh sync           [--public|--private] <org> [dir]
#   ./org-config.sh workflows-sync [--public|--private] <org> [dir]
#   ./org-config.sh teams-sync     [--public|--private] <org>
#
# org defaults to bitwise-media-group. The *-sync commands fan config out across
# the org's repos and take --public / --private to limit which repos by
# visibility. labels-sync, sync, and workflows-sync read a snapshot dir
# (default: ./repo-config):
#   labels-sync     applies only <dir>/labels.json to each repo.
#   sync            runs the full repo-config.sh import (settings, rulesets, labels).
#   workflows-sync  commits each <dir>/workflows/*.yaml into .github/workflows/ of
#                   every repo (upsert only, never deletes), links the shared project
#                   onto each, and backfills each repo's existing issues into it — this
#                   is how the add-to-project caller is wired into every repo.
#   teams-sync      grants a team (default: bitwise-maintainers) a permission
#                   (default: maintain) on every repo; takes no dir.
#
# What's covered:
#   - Organisation-level rulesets only (full definitions: conditions, rules,
#     bypass_actors); rulesets inherited from an enterprise are ignored in both
#     directions. Org rulesets share the repo-ruleset shape but their conditions
#     also target which repositories they apply to (repository_name /
#     repository_property), captured as part of conditions.
#   - General org settings, grouped as:
#       member-privileges  default_repository_permission,
#                          members_can_create_repositories and the
#                          public/private/internal/pages variants,
#                          members_can_fork_private_repositories
#       new-repo defaults  dependabot / dependency-graph / secret-scanning
#                          toggles applied to repositories created in the org
#       commits            web_commit_signoff_required
#
# Deliberately excluded: identity (name, description, billing_email, company,
# email, location, blog), plan/seat data, and anything server-managed.
#
# Mirror semantics: both directions sync rather than merge.
#   - export wipes <dir>/rulesets first, so it reflects exactly what's live.
#   - import makes the org's rulesets match <dir>/rulesets: update/create the
#     ones with a file, delete any ruleset that has no matching file. A missing
#     rulesets dir is left untouched; an empty one means "remove them all".
#
# Labels: GitHub has no org-level labels API — org "default labels" are a UI-only
# setting that merely seeds NEW repos. So labels-sync instead fans a canonical
# repo-config/labels.json out to EVERY non-archived repo in the org, applying the
# same upsert + delete mirror logic repo-config.sh uses (this also covers repos
# that already exist). Destructive by design: a label absent from the file is
# deleted from each repo, which removes it from that repo's issues/PRs. Set
# KEEP_EXTRA=1 to only add/update and never delete.
#
# Teams: teams-sync grants one org team a single permission on EVERY non-archived
# repo in the org, so a standing maintainer team gets access to repos created
# after it was set up. Defaults to the bitwise-maintainers team at maintain (the
# "as maintainers" access level); override with TEAM / TEAM_PERMISSION. Purely
# additive and idempotent: GitHub's team-repo PUT upserts the grant, and the
# command never removes a team from a repo (no mirror/delete pass).
#
# Workflows: workflows-sync fans <dir>/workflows/*.yaml out to .github/workflows/ in
# EVERY non-archived repo via the Contents API, committing to the default branch. It
# is how the org-sync wires up the add-to-project caller (repo-config/workflows/
# add-to-project.yaml) so newly opened issues land in the shared Roadmap project.
# Additive/upsert only: it creates or updates exactly the files it holds and never
# deletes anything, so a repo's other workflows are untouched. Idempotent — it skips a
# repo whose file already matches byte-for-byte, making no empty commit. The commit
# carries a Signed-off-by trailer (satisfying web_commit_signoff_required), but a
# Contents-API commit is NOT signed — GitHub only web-flow-signs commits made in the web
# UI or by a GitHub App, not an OAuth-token API write — so it does not satisfy
# required_signatures. On a public repo's default branch that means the org owner must
# bypass three rules for the push to land: pull_request, required_signatures
# (public-release-branch-security), and code_scanning (public-code-quality) — so
# OrganizationAdmin is a bypass actor on all three rulesets. A single commit on the tip
# already satisfies required_linear_history / non_fast_forward. Writing under
# .github/workflows/ needs the token's `workflow` scope. One-time org setup (the
# "Project Sync" App + ADD_TO_PROJECT_CLIENT_ID / ADD_TO_PROJECT_PRIVATE_KEY) lives in
# that caller's header and github-workflows' add-to-project.yaml.
#   In the same pass it links the shared project (PROJECT_NUMBER, default 1 = Roadmap)
#   onto each repo so the board also appears on the repo's Projects tab, using the
#   first-party `gh project link`. It reads which repos are already linked and only links
#   new ones — an org owner's gh token has the project write access that needs; a re-run
#   over already-linked repos is read-only. Never unlinks. Then it backfills the repo's
#   existing issues (ISSUE_STATE, default open) into the board via `gh project item-add`,
#   so work opened before the workflow existed is caught up too; the add dedupes, so
#   re-runs make no duplicates. Set PROJECT_NUMBER=0 to fan the files out without touching
#   the project at all, or ISSUE_STATE=none to link but skip the issue backfill.
#
# Env:
#   STRIP_BYPASS=1   drop ruleset bypass_actors on export — use when the bypass
#                    actors (teams, apps, custom roles) won't exist in the target.
#   KEEP_EXTRA=1     labels-sync only: add/update labels but never delete ones a
#                    repo has that aren't in labels.json (additive, not mirror).
#   PROJECT_NUMBER   workflows-sync only: org project to link + backfill into (default 1,
#                    the Roadmap board); 0 skips all project work.
#   ISSUE_STATE      workflows-sync only: which existing issues to backfill —
#                    open (default) | closed | all | none (skip the backfill).
#   TEAM=<slug>      teams-sync only: org team to grant (default bitwise-maintainers).
#   TEAM_PERMISSION  teams-sync only: pull|triage|push|maintain|admin or a custom
#                    role name (default maintain).
#
# Requires: gh (authenticated, org owner), jq.
# Note: reading/writing org settings and rulesets requires organisation owner;
#       switch accounts with `gh auth switch` if the active one lacks access.
#       workflows-sync additionally needs the active token's `workflow` scope to write
#       under .github/workflows/ (gh auth refresh -s workflow), must run as an org owner
#       so its unsigned Contents-API commits bypass the default-branch rules, and links
#       the board via `gh project link` (project write, which an org-owner gh token has).

SETTINGS_FILTER='{
  default_repository_permission,
  members_can_create_repositories,
  members_can_create_public_repositories,
  members_can_create_private_repositories,
  members_can_create_internal_repositories,
  members_can_create_pages,
  members_can_create_public_pages,
  members_can_create_private_pages,
  members_can_fork_private_repositories,
  web_commit_signoff_required,
  dependabot_alerts_enabled_for_new_repositories,
  dependabot_security_updates_enabled_for_new_repositories,
  dependency_graph_enabled_for_new_repositories,
  secret_scanning_enabled_for_new_repositories,
  secret_scanning_push_protection_enabled_for_new_repositories,
}'

usage() {
  echo "usage: $0 export <org> [dir]" >&2
  echo "       $0 import <org> [dir]" >&2
  echo "       $0 labels-sync    [--public|--private] <org> [dir]   (dir default: repo-config)" >&2
  echo "       $0 sync           [--public|--private] <org> [dir]   (dir default: repo-config)" >&2
  echo "       $0 workflows-sync [--public|--private] <org> [dir]   (dir default: repo-config)" >&2
  echo "       $0 teams-sync     [--public|--private] <org>         (team default: bitwise-maintainers)" >&2
  echo "       (org defaults to bitwise-media-group)" >&2
  exit 2
}

gh=/opt/homebrew/bin/gh
here=$(dirname "$0")

# teams-sync target: which org team gets which permission on every repo.
team=${TEAM:-bitwise-maintainers}
team_permission=${TEAM_PERMISSION:-maintain}

# workflows-sync also links this org Projects v2 board onto each repo (so it shows on
# the repo's Projects tab). It is the board number in the project URL — keep it in step
# with the project-url in repo-config/workflows/add-to-project.yaml. Set PROJECT_NUMBER=0
# to skip linking and only fan the workflow files out.
project_number=${PROJECT_NUMBER:-1}

# workflows-sync also backfills each repo's existing issues into that project, so the
# board catches up on work opened before the add-to-project workflow existed. Which
# issues: open (default), closed, all, or none to skip the backfill. PRs are never added.
issue_state=${ISSUE_STATE:-open}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

# Flags may appear anywhere among the args; positionals are <org> then [dir].
visibility=all
org=bitwise-media-group
dir=""
seen=0
while [ $# -gt 0 ]; do
  case "$1" in
  --public) visibility=public ;;
  --private) visibility=private ;;
  -*)
    echo "unknown flag: $1" >&2
    usage
    ;;
  *)
    seen=$((seen + 1))
    if [ "$seen" -eq 1 ]; then
      org=$1
    elif [ "$seen" -eq 2 ]; then
      dir=$1
    else
      echo "unexpected arg: $1" >&2
      usage
    fi
    ;;
  esac
  shift
done

export_config() {
  mkdir -p "$dir/rulesets"

  # General settings (member-privileges / new-repo defaults / commits). Drop
  # nulls so plan-gated fields absent on this org aren't PATCHed back as null.
  ${gh} api "orgs/$org" | jq "$SETTINGS_FILTER | with_entries(select(.value != null))" >"$dir/settings.json"
  echo "exported settings  -> $dir/settings.json"

  # Mirror reality: drop previously-exported rulesets so any removed upstream
  # don't linger here as stale files.
  rm -f "$dir"/rulesets/*.json

  # Rulesets: fetch each full definition, reduce to the create payload, and
  # name the file after the (sanitized) ruleset name for readability.
  strip='.'
  [ -n "${STRIP_BYPASS:-}" ] && strip='del(.bypass_actors)'
  ${gh} api --paginate "orgs/$org/rulesets?includes_parents=false" --jq '.[].id' | while read -r id; do
    [ -n "$id" ] || continue
    full=$(${gh} api "orgs/$org/rulesets/$id")
    name=$(printf '%s' "$full" | jq -r '.name')
    safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')
    printf '%s' "$full" |
      jq "{name, target, enforcement, bypass_actors, conditions, rules}
            | with_entries(select(.value != null)) | $strip" \
        >"$dir/rulesets/$safe.json"
    echo "exported ruleset   -> $dir/rulesets/$safe.json"
  done
}

import_config() {
  if [ -f "$dir/settings.json" ]; then
    ${gh} api -X PATCH "orgs/$org" --input "$dir/settings.json" >/dev/null
    echo "applied settings   <- $dir/settings.json"
  else
    echo "no $dir/settings.json; skipping settings" >&2
  fi

  # Rulesets: mirror the files onto the org. A missing rulesets dir is left
  # alone; an empty dir is a real instruction to remove every ruleset.
  if [ -d "$dir/rulesets" ]; then
    tab=$(printf '\t')

    # Snapshot the org's current rulesets as "<id>\t<name>" lines.
    remote=$(${gh} api --paginate "orgs/$org/rulesets?includes_parents=false" --jq '.[] | [.id, .name] | @tsv')

    # The set of names we hold a file for (one per line).
    names=$(
      for f in "$dir"/rulesets/*.json; do
        [ -e "$f" ] || continue
        jq -r '.name' "$f"
      done
    )

    # Upsert: PUT when a ruleset of that name already exists, POST when it's new.
    # A failure is reported but does not abort the rest (gh prints to stderr).
    for f in "$dir"/rulesets/*.json; do
      [ -e "$f" ] || continue
      name=$(jq -r '.name' "$f")
      id=$(printf '%s\n' "$remote" | awk -F"$tab" -v n="$name" '$2 == n {print $1; exit}')
      if [ -n "$id" ]; then
        if ${gh} api -X PUT "orgs/$org/rulesets/$id" --input "$f" >/dev/null; then
          echo "updated ruleset    <- $name"
        else
          echo "FAILED ruleset     <- $name (see error above)" >&2
        fi
      elif ${gh} api -X POST "orgs/$org/rulesets" --input "$f" >/dev/null; then
        echo "created ruleset    <- $name"
      else
        echo "FAILED ruleset     <- $name (see error above)" >&2
      fi
    done

    # Delete: every remote ruleset without a matching file.
    printf '%s\n' "$remote" | while IFS="$tab" read -r id name; do
      [ -n "$id" ] || continue
      if printf '%s\n' "$names" | grep -Fxq -- "$name"; then
        continue
      fi
      if ${gh} api -X DELETE "orgs/$org/rulesets/$id" >/dev/null; then
        echo "deleted ruleset    -> $name (no local file)"
      else
        echo "FAILED delete      -> $name (see error above)" >&2
      fi
    done
  fi
}

# Apply a labels.json to a single repo with the same mirror logic as
# repo-config.sh import: PATCH existing, POST new, and (unless KEEP_EXTRA) DELETE
# any label the repo has that the file doesn't list. Names may contain spaces or
# slashes, so URL-encode them for the path.
sync_labels_to_repo() {
  repo=$1
  labels_file=$2

  want=$(jq -r '.[].name' "$labels_file")
  remote=$(${gh} api --paginate "repos/$repo/labels" --jq '.[].name')

  jq -c '.[]' "$labels_file" | while read -r label; do
    name=$(printf '%s' "$label" | jq -r '.name')
    enc=$(printf '%s' "$name" | jq -sRr @uri)
    if printf '%s\n' "$remote" | grep -Fxq -- "$name"; then
      if printf '%s' "$label" | jq '{color, description} | with_entries(select(.value != null))' |
        ${gh} api -X PATCH "repos/$repo/labels/$enc" --input - >/dev/null; then
        echo "  updated  <- $name"
      else
        echo "  FAILED   <- $name (see error above)" >&2
      fi
    elif printf '%s' "$label" | ${gh} api -X POST "repos/$repo/labels" --input - >/dev/null; then
      echo "  created  <- $name"
    else
      echo "  FAILED   <- $name (see error above)" >&2
    fi
  done

  [ -n "${KEEP_EXTRA:-}" ] && return 0

  printf '%s\n' "$remote" | while read -r name; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$want" | grep -Fxq -- "$name"; then
      continue
    fi
    enc=$(printf '%s' "$name" | jq -sRr @uri)
    if ${gh} api -X DELETE "repos/$repo/labels/$enc" >/dev/null; then
      echo "  deleted  -> $name (no local entry)"
    else
      echo "  FAILED   -> $name (see error above)" >&2
    fi
  done
}

# Fan <dir>/labels.json out to every non-archived repo in the org. Archived repos
# are read-only and skipped; per-repo failures are reported and don't abort the run.
labels_sync() {
  labels_file="$dir/labels.json"
  [ -f "$labels_file" ] || {
    echo "no $labels_file; nothing to sync" >&2
    exit 1
  }

  ${gh} api --paginate "orgs/$org/repos?type=$visibility" \
    --jq '.[] | select(.archived | not) | .full_name' | while read -r repo; do
    [ -n "$repo" ] || continue
    echo "syncing labels -> $repo"
    sync_labels_to_repo "$repo" "$labels_file"
  done
}

# Run repo-config.sh import on every non-archived repo in the org, optionally
# filtered by visibility. repo-config.sh applies the same <dir> snapshot
# (settings, rulesets, labels) to each. Per-repo failures are reported but don't
# abort the run.
repo_sync() {
  repo_config="$here/repo-config.sh"
  [ -x "$repo_config" ] || {
    echo "missing or non-executable $repo_config" >&2
    exit 1
  }

  ${gh} api --paginate "orgs/$org/repos?type=$visibility" \
    --jq '.[] | select(.archived | not) | .name' | while read -r name; do
    [ -n "$name" ] || continue
    echo "=== syncing $name ==="
    "$repo_config" import "$name" "$dir" ||
      echo "FAILED sync -> $name (see error above)" >&2
  done
}

# Grant $team the $team_permission level on every non-archived repo in the org,
# optionally filtered by visibility. GitHub's team-repo PUT is an upsert, so this
# is idempotent and re-asserts access on repos that already have it; it never
# removes the team (additive, no mirror/delete pass). Archived repos are
# read-only and skipped. Per-repo failures are reported but don't abort the run.
teams_sync() {
  ${gh} api --paginate "orgs/$org/repos?type=$visibility" \
    --jq '.[] | select(.archived | not) | .name' | while read -r name; do
    [ -n "$name" ] || continue
    if ${gh} api -X PUT "orgs/$org/teams/$team/repos/$org/$name" \
      -f permission="$team_permission" >/dev/null; then
      echo "granted $team ($team_permission) -> $name"
    else
      echo "FAILED team        -> $name (see error above)" >&2
    fi
  done
}

# Commit one file into a repo at $path on its default branch via the Contents API.
# Idempotent: fetch the current file first and skip the PUT when it is byte-identical
# (a trailing-newline difference is ignored — command substitution strips it from both
# sides), so re-runs make no empty commits. A blob sha is required to update an existing
# file and omitted when creating. $signoff (set by the caller) supplies the Signed-off-by
# trailer that web_commit_signoff_required expects; the commit itself is signed by GitHub.
push_file_to_repo() {
  repo=$1
  path=$2
  file=$3

  remote=$(${gh} api "repos/$repo/contents/$path" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null || true)
  if [ -n "$remote" ] && [ "$remote" = "$(cat "$file")" ]; then
    echo "  unchanged  == $path"
    return 0
  fi

  sha=$(${gh} api "repos/$repo/contents/$path" --jq '.sha' 2>/dev/null || true)

  payload=$(jq -n \
    --arg m "chore: sync $path from github-settings

Signed-off-by: $signoff" \
    --arg c "$(base64 <"$file" | tr -d '\n')" \
    --arg s "$sha" \
    '{message: $m, content: $c} + (if $s == "" then {} else {sha: $s} end)')

  if printf '%s' "$payload" | ${gh} api -X PUT "repos/$repo/contents/$path" --input - >/dev/null; then
    if [ -n "$sha" ]; then
      echo "  updated    <- $path"
    else
      echo "  created    <- $path"
    fi
  else
    echo "  FAILED     <- $path (see error above)" >&2
  fi
}

# Link the shared org project (#$project_number) onto a repo so it appears on the repo's
# Projects tab. Uses the first-party `gh project link` rather than a hand-built GraphQL
# mutation, so there is no query string to mis-quote. Idempotent by construction:
# $project_linked holds the repos already linked (fetched once, read-only), so a re-run
# skips the write entirely — only a genuinely new link calls `gh project link` (which
# needs the token's `project` scope). A link failure is reported, not fatal.
link_project_to_repo() {
  repo=$1

  if printf '%s\n' "$project_linked" | grep -Fxq -- "$repo"; then
    echo "  linked     == project #$project_number (already)"
    return 0
  fi

  if ${gh} project link "$project_number" --owner "$org" --repo "$repo" >/dev/null; then
    echo "  linked     -> project #$project_number"
  else
    echo "  FAILED     -> link project #$project_number (see error above)" >&2
  fi
}

# Add a repo's existing issues to the shared project so the board catches up on work
# opened before the add-to-project workflow existed. Uses `gh project item-add`, whose
# addProjectV2ItemById path dedupes — an issue already on the board is a no-op, so
# re-runs add no duplicates (they just re-assert each item). $issue_state (open|closed|
# all) picks which issues; PRs are never added (gh issue list lists issues only). A repo
# with issues disabled lists nothing. Per-issue failures are reported, not fatal.
backfill_issues_to_project() {
  repo=$1
  ${gh} issue list --repo "$repo" --state "$issue_state" --limit 1000 \
    --json url --jq '.[].url' 2>/dev/null | while read -r url; do
    [ -n "$url" ] || continue
    if ${gh} project item-add "$project_number" --owner "$org" --url "$url" >/dev/null; then
      echo "  added issue -> $url"
    else
      echo "  FAILED add  -> $url (see error above)" >&2
    fi
  done
}

# Fan every <dir>/workflows/*.yaml out to .github/workflows/ in each non-archived repo,
# optionally filtered by visibility; link the shared org project (PROJECT_NUMBER) onto
# each so it also shows on the repo's Projects tab; and backfill each repo's existing
# issues (ISSUE_STATE) into that project so the board catches up on work opened before
# the workflow existed. Additive/upsert only — it creates or updates just the files it
# holds and never deletes, so a repo's other workflows are untouched; linking never
# unlinks and the issue backfill dedupes. Per-repo/-file failures are reported and don't
# abort the run.
workflows_sync() {
  wf_dir="$dir/workflows"
  [ -d "$wf_dir" ] || {
    echo "no $wf_dir; nothing to sync" >&2
    exit 1
  }

  found=0
  for f in "$wf_dir"/*.yaml "$wf_dir"/*.yml; do
    [ -e "$f" ] && found=1
  done
  [ "$found" -eq 1 ] || {
    echo "no workflow files in $wf_dir; nothing to sync" >&2
    exit 1
  }

  # Sign-off identity for web_commit_signoff_required, resolved once from the active gh
  # account; fall back to the GitHub noreply address when the account hides its email.
  gh_login=$(${gh} api user --jq '.login')
  gh_name=$(${gh} api user --jq '.name // .login')
  gh_id=$(${gh} api user --jq '.id')
  gh_email=$(${gh} api user --jq '.email // empty')
  [ -n "$gh_email" ] || gh_email="${gh_id}+${gh_login}@users.noreply.github.com"
  signoff="$gh_name <$gh_email>"

  # Resolve the shared project and the repos already linked to it, once and read-only.
  # PROJECT_NUMBER=0 (or a project the account can't see) leaves project_id empty and
  # skips linking entirely — the workflow files still sync.
  project_id=""
  project_linked=""
  if [ "$project_number" -ne 0 ]; then
    project_id=$(${gh} api graphql \
      -f query="{organization(login: \"$org\") {projectV2(number: $project_number) {id}}}" \
      --jq '.data.organization.projectV2.id' 2>/dev/null || true)
    if [ -n "$project_id" ]; then
      project_linked=$(${gh} api graphql \
        -f query="{organization(login: \"$org\") {projectV2(number: $project_number) {repositories(first: 100) {nodes {nameWithOwner}}}}}" \
        --jq '.data.organization.projectV2.repositories.nodes[].nameWithOwner' 2>/dev/null || true)
    else
      echo "project #$project_number not found on $org; skipping project links" >&2
    fi
  fi

  ${gh} api --paginate "orgs/$org/repos?type=$visibility" \
    --jq '.[] | select(.archived | not) | .full_name' | while read -r repo; do
    [ -n "$repo" ] || continue
    echo "syncing workflows -> $repo"
    for f in "$wf_dir"/*.yaml "$wf_dir"/*.yml; do
      [ -e "$f" ] || continue
      push_file_to_repo "$repo" ".github/workflows/$(basename "$f")" "$f"
    done
    if [ -n "$project_id" ]; then
      link_project_to_repo "$repo"
      if [ "$issue_state" != none ]; then
        backfill_issues_to_project "$repo"
      fi
    fi
  done
}

case "$cmd" in
export)
  dir="${dir:-org-config}"
  export_config
  ;;
import)
  dir="${dir:-org-config}"
  import_config
  ;;
labels-sync)
  dir="${dir:-repo-config}"
  labels_sync
  ;;
sync)
  dir="${dir:-repo-config}"
  repo_sync
  ;;
workflows-sync)
  dir="${dir:-repo-config}"
  workflows_sync
  ;;
teams-sync)
  teams_sync
  ;;
*) usage ;;
esac
