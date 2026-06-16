#!/usr/bin/env sh
set -eu

# repo-config.sh — export/import a GitHub repository's rulesets, labels, and
# general settings, for templating new repos or recreating this one.
#
#   ./repo-config.sh export <repo> [dir]   # dump config  -> dir (default: ./repo-config)
#   ./repo-config.sh import <repo> [dir]   # apply config <- dir
#
# <repo> is the bare repository name; the org is always bitwise-media-group.
#
# What's covered:
#   - Repository-level rulesets only (full definitions: conditions, rules,
#     bypass_actors). Org-level rulesets that merely apply to this repo are
#     ignored in both directions — manage those with org-config.sh.
#   - Labels (name, color, description) as a single labels.json array.
#   - General settings, grouped as:
#       features       has_issues, has_projects, has_wiki, has_discussions
#       pull-requests  allow_squash_merge, allow_merge_commit, allow_rebase_merge,
#                      allow_auto_merge, allow_update_branch, delete_branch_on_merge
#       commits        squash/merge commit title+message templates,
#                      web_commit_signoff_required
#
# Deliberately excluded: identity (name, description, homepage), default_branch
# (target may not have the branch yet), and anything server-managed.
#
# Mirror semantics: both directions sync rather than merge.
#   - export wipes <dir>/rulesets first, so it reflects exactly what's live.
#   - import makes the repo's rulesets match <dir>/rulesets: update/create the
#     ones with a file, delete any ruleset that has no matching file. A missing
#     rulesets dir is left untouched; an empty one means "remove them all".
#   - labels.json mirrors the same way by entry: update/create the labels listed,
#     delete any repo label absent from it. A missing labels.json is left
#     untouched; an empty array ([]) means "remove them all".
#
# Env:
#   STRIP_BYPASS=1   drop ruleset bypass_actors on export — use when the bypass
#                    actors (teams, apps, custom roles) won't exist in the target.
#
# Requires: gh (authenticated, admin on the repo), jq.
# Note: reading/writing rulesets requires admin; switch accounts with
#       `gh auth switch` if the active one lacks access.

SETTINGS_FILTER='{
  has_issues, has_projects, has_wiki, has_discussions,
  allow_squash_merge, allow_merge_commit, allow_rebase_merge,
  allow_auto_merge, allow_update_branch, delete_branch_on_merge,
  squash_merge_commit_title, squash_merge_commit_message,
  merge_commit_title, merge_commit_message,
}'

ORG=bitwise-media-group

usage() {
  echo "usage: $0 export <repo> [dir]   (org is always $ORG)" >&2
  echo "       $0 import <repo> [dir]" >&2
  exit 2
}

cmd="${1:-}"
name="${2:-}"
dir="${3:-repo-config}"
[ -n "$cmd" ] && [ -n "$name" ] || usage

repo="$ORG/$name"

export_config() {
  mkdir -p "$dir/rulesets"

  # General settings (features / pull-requests / commits).
  gh api "repos/$repo" | jq "$SETTINGS_FILTER" >"$dir/settings.json"
  echo "exported settings  -> $dir/settings.json"

  # Mirror reality: drop previously-exported rulesets so any removed upstream
  # don't linger here as stale files.
  rm -f "$dir"/rulesets/*.json

  # Rulesets: fetch each full definition, reduce to the create payload, and
  # name the file after the (sanitized) ruleset name for readability.
  strip='.'
  [ -n "${STRIP_BYPASS:-}" ] && strip='del(.bypass_actors)'
  gh api --paginate "repos/$repo/rulesets?includes_parents=false" --jq '.[].id' | while read -r id; do
    [ -n "$id" ] || continue
    full=$(gh api "repos/$repo/rulesets/$id")
    name=$(printf '%s' "$full" | jq -r '.name')
    safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-')
    printf '%s' "$full" |
      jq "{name, target, enforcement, bypass_actors, conditions, rules}
            | with_entries(select(.value != null)) | $strip" \
        >"$dir/rulesets/$safe.json"
    echo "exported ruleset   -> $dir/rulesets/$safe.json"
  done

  # Labels: a single array of {name, color, description}; export overwrites the
  # file so it reflects exactly what's live. Drop null descriptions for clean
  # payloads (name and color are always present).
  gh api --paginate "repos/$repo/labels" |
    jq 'map({name, color, description} | with_entries(select(.value != null)))' \
      >"$dir/labels.json"
  echo "exported labels    -> $dir/labels.json"
}

import_config() {
  if [ -f "$dir/settings.json" ]; then
    gh api -X PATCH "repos/$repo" --input "$dir/settings.json" >/dev/null
    echo "applied settings   <- $dir/settings.json"
  else
    echo "no $dir/settings.json; skipping settings" >&2
  fi

  # Rulesets: mirror the files onto the repo. A missing rulesets dir is left
  # alone; an empty dir is a real instruction to remove every ruleset.
  if [ -d "$dir/rulesets" ]; then
    tab=$(printf '\t')

    # Snapshot the repo's current rulesets as "<id>\t<name>" lines.
    remote=$(gh api --paginate "repos/$repo/rulesets?includes_parents=false" --jq '.[] | [.id, .name] | @tsv')

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
        if gh api -X PUT "repos/$repo/rulesets/$id" --input "$f" >/dev/null; then
          echo "updated ruleset    <- $name"
        else
          echo "FAILED ruleset     <- $name (see error above)" >&2
        fi
      elif gh api -X POST "repos/$repo/rulesets" --input "$f" >/dev/null; then
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
      if gh api -X DELETE "repos/$repo/rulesets/$id" >/dev/null; then
        echo "deleted ruleset    -> $name (no local file)"
      else
        echo "FAILED delete      -> $name (see error above)" >&2
      fi
    done
  fi

  # Labels: mirror labels.json onto the repo. A missing file is left alone; an
  # empty array ([]) is a real instruction to remove every label.
  if [ -f "$dir/labels.json" ]; then
    # The set of names we hold an entry for (one per line).
    want=$(jq -r '.[].name' "$dir/labels.json")

    # Snapshot the repo's current label names.
    remote=$(gh api --paginate "repos/$repo/labels" --jq '.[].name')

    # Upsert: PATCH when a label of that name exists, POST when it's new. Names
    # may contain spaces or slashes, so URL-encode them for the path.
    jq -c '.[]' "$dir/labels.json" | while read -r label; do
      name=$(printf '%s' "$label" | jq -r '.name')
      enc=$(printf '%s' "$name" | jq -sRr @uri)
      if printf '%s\n' "$remote" | grep -Fxq -- "$name"; then
        if printf '%s' "$label" | jq '{color, description} | with_entries(select(.value != null))' |
          gh api -X PATCH "repos/$repo/labels/$enc" --input - >/dev/null; then
          echo "updated label      <- $name"
        else
          echo "FAILED label       <- $name (see error above)" >&2
        fi
      elif printf '%s' "$label" | gh api -X POST "repos/$repo/labels" --input - >/dev/null; then
        echo "created label      <- $name"
      else
        echo "FAILED label       <- $name (see error above)" >&2
      fi
    done

    # Delete: every remote label without a matching entry.
    printf '%s\n' "$remote" | while read -r name; do
      [ -n "$name" ] || continue
      if printf '%s\n' "$want" | grep -Fxq -- "$name"; then
        continue
      fi
      enc=$(printf '%s' "$name" | jq -sRr @uri)
      if gh api -X DELETE "repos/$repo/labels/$enc" >/dev/null; then
        echo "deleted label      -> $name (no local entry)"
      else
        echo "FAILED delete      -> $name (see error above)" >&2
      fi
    done
  else
    echo "no $dir/labels.json; skipping labels" >&2
  fi
}

case "$cmd" in
export) export_config ;;
import) import_config ;;
*) usage ;;
esac
