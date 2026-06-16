#!/usr/bin/env sh
set -eu

# org-config.sh — export/import a GitHub organisation's rulesets and general
# settings, plus fan repo labels out across the org; the org-level companion to
# repo-config.sh.
#
#   ./org-config.sh export <org> [dir]        # dump config  -> dir (default: ./org-config)
#   ./org-config.sh import <org> [dir]        # apply config <- dir
#   ./org-config.sh labels-sync [--public|--private] <org> [dir]
#   ./org-config.sh sync        [--public|--private] <org> [dir]
#
# org defaults to bitwise-media-group. The two *-sync commands fan config out
# across the org's repos (default dir: ./repo-config) and take --public /
# --private to limit which repos by visibility:
#   labels-sync  applies only <dir>/labels.json to each repo.
#   sync         runs the full repo-config.sh import (settings, rulesets, labels).
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
# Env:
#   STRIP_BYPASS=1   drop ruleset bypass_actors on export — use when the bypass
#                    actors (teams, apps, custom roles) won't exist in the target.
#   KEEP_EXTRA=1     labels-sync only: add/update labels but never delete ones a
#                    repo has that aren't in labels.json (additive, not mirror).
#
# Requires: gh (authenticated, org owner), jq.
# Note: reading/writing org settings and rulesets requires organisation owner;
#       switch accounts with `gh auth switch` if the active one lacks access.

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
  echo "       $0 labels-sync [--public|--private] <org> [dir]   (dir default: repo-config)" >&2
  echo "       $0 sync        [--public|--private] <org> [dir]   (dir default: repo-config)" >&2
  echo "       (org defaults to bitwise-media-group)" >&2
  exit 2
}

gh=/opt/homebrew/bin/gh
here=$(dirname "$0")

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
*) usage ;;
esac
