#!/usr/bin/env bash
# Distribute template files to target repos. Used by both the GitHub Actions
# workflow (.github/workflows/distribute-template.yml) and local dry-runs.
#
# Inputs (env):
#   DISTRIBUTE_TARGETS  JSON string with { targets: [...] } (preferred in CI)
#   TARGETS_FILE        Path to JSON file with the same shape (local fallback)
#   STRATEGIES_FILE     Path to strategies JSON (default: .github/distribute-strategies.json)
#   MODE                'dry-run' (default) | 'apply'
#   TARGET              Optional single repo name to limit the run
#   CHANGED_FILES       Optional newline-separated list of source paths to filter by.
#                       When set, only targets that include at least one of these
#                       paths in their `files` allowlist are processed.
#   OWNER               GitHub owner/org (default: malleroid)
#   SYNC_BRANCH         Branch name used in target repos (default: chore/sync-from-template)
#   GH_TOKEN            Auth for `gh` CLI (set by workflow; locally use `gh auth login`)
#   KEEP                '1' to retain WORK_DIR after the run (default: 0)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STRATEGIES_FILE="${STRATEGIES_FILE:-$ROOT/.github/distribute-strategies.json}"
WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-$ROOT/tmp}/distribute-work}"
MODE="${MODE:-dry-run}"
TARGET="${TARGET:-}"
OWNER="${OWNER:-malleroid}"
SYNC_BRANCH="${SYNC_BRANCH:-chore/sync-from-template}"
PR_TITLE="${PR_TITLE:-chore: sync configuration from template}"
PR_BODY="${PR_BODY:-Automated sync from template repository.}"
KEEP="${KEEP:-0}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Error: $1 not found" >&2; exit 1; } ; }
require jq
require gh
require git

if [[ -n "${DISTRIBUTE_TARGETS:-}" ]]; then
  TARGETS_JSON="$DISTRIBUTE_TARGETS"
elif [[ -n "${TARGETS_FILE:-}" && -f "$TARGETS_FILE" ]]; then
  TARGETS_JSON="$(cat "$TARGETS_FILE")"
elif [[ -f "$ROOT/.claude/skills/distribute-template/distribute-targets.json" ]]; then
  TARGETS_JSON="$(cat "$ROOT/.claude/skills/distribute-template/distribute-targets.json")"
else
  echo "Error: provide DISTRIBUTE_TARGETS env or TARGETS_FILE path" >&2
  exit 1
fi

[[ -f "$STRATEGIES_FILE" ]] || { echo "Error: strategies file not found: $STRATEGIES_FILE" >&2; exit 1; }

# Build CHANGED_FILES_JSON (JSON array) from CHANGED_FILES env (newline-separated).
if [[ -n "${CHANGED_FILES:-}" ]]; then
  CHANGED_FILES_JSON=$(jq -Rn '[inputs | select(length > 0)]' <<<"$CHANGED_FILES")
  echo "Changed-files filter: $(jq 'length' <<<"$CHANGED_FILES_JSON") path(s)"
else
  CHANGED_FILES_JSON=""
fi

# Keep only file entries whose source path matches CHANGED_FILES.
filter_files() {
  local files_json="$1"
  if [[ -z "$CHANGED_FILES_JSON" ]]; then
    printf '%s' "$files_json"
    return
  fi
  jq --argjson changed "$CHANGED_FILES_JSON" '
    map(select(
      (if type == "string" then . else .source end) as $src
      | $changed | index($src) != null
    ))
  ' <<<"$files_json"
}

# In CI: mask every target repo name before doing anything that could log it,
# and configure git/gh for cross-repo pushes via the provided token.
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  while IFS= read -r r; do
    [[ -n "$r" ]] && echo "::add-mask::$r"
  done < <(jq -r '.targets[].repo' <<<"$TARGETS_JSON")
  git config --global user.name "github-actions[bot]"
  git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
  gh auth setup-git
fi

mkdir -p "$WORK_DIR"

cleanup() {
  if [[ "$KEEP" == "1" ]]; then
    echo "Keeping work dir"
  else
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

get_strategy() {
  jq -r --arg f "$1" '.files[$f] // .default' "$STRATEGIES_FILE"
}

apply_file() {
  local repo_dir="$1" source="$2" target="$3"
  local strategy
  strategy=$(get_strategy "$source")

  local src="$ROOT/$source"
  local dst="$repo_dir/$target"

  if [[ ! -f "$src" ]]; then
    echo "  ⚠️  template missing: $source"
    return 0
  fi

  case "$strategy" in
    overwrite)
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
      ;;
    skip)
      if [[ ! -f "$dst" ]]; then
        echo "  🆕 [skip] $target absent (report only)"
      elif ! diff -q "$src" "$dst" >/dev/null 2>&1; then
        echo "  📝 [skip] diff in $target (report only):"
        diff -u "$dst" "$src" | sed 's/^/      /' || true
      fi
      ;;
    *)
      echo "  ❌ unknown strategy '$strategy' for $source" >&2
      return 1
      ;;
  esac
}

process_target() {
  local repo="$1" files_json
  files_json=$(filter_files "$2")

  echo
  echo "===== $repo ====="

  if [[ "$(jq 'length' <<<"$files_json")" == "0" ]]; then
    echo "  ⏭️  no files match changeset, skipping"
    return 0
  fi

  local repo_dir="$WORK_DIR/$repo"
  rm -rf "$repo_dir"

  if ! gh repo clone "$OWNER/$repo" "$repo_dir" -- --depth=1 --quiet 2>/dev/null; then
    echo "  ❌ clone failed"
    return 1
  fi

  git -C "$repo_dir" checkout -B "$SYNC_BRANCH" >/dev/null 2>&1

  while IFS= read -r entry; do
    local entry_type
    entry_type=$(jq -r 'type' <<<"$entry")
    if [[ "$entry_type" == "string" ]]; then
      local path
      path=$(jq -r '.' <<<"$entry")
      apply_file "$repo_dir" "$path" "$path"
    else
      local source
      source=$(jq -r '.source' <<<"$entry")
      while IFS= read -r tpath; do
        apply_file "$repo_dir" "$source" "$tpath"
      done < <(jq -r '.targets[]' <<<"$entry")
    fi
  done < <(jq -c '.[]' <<<"$files_json")

  if [[ -z $(git -C "$repo_dir" status --porcelain) ]]; then
    echo "  ✅ no changes"
    return 0
  fi

  echo "  📋 changes:"
  git -C "$repo_dir" --no-pager diff --stat | sed 's/^/      /'

  if [[ "$MODE" == "dry-run" ]]; then
    echo "  (dry-run) skipping commit/push/PR"
    return 0
  fi

  git -C "$repo_dir" add -A
  git -C "$repo_dir" commit -m "$PR_TITLE" >/dev/null
  git -C "$repo_dir" push -u origin "$SYNC_BRANCH" --force-with-lease >/dev/null 2>&1

  local open_count
  open_count=$(gh pr list --repo "$OWNER/$repo" --head "$SYNC_BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo 0)
  if [[ "$open_count" -gt 0 ]]; then
    echo "  ✅ PR updated"
  else
    gh pr create \
      --repo "$OWNER/$repo" \
      --base main \
      --head "$SYNC_BRANCH" \
      --title "$PR_TITLE" \
      --body "$PR_BODY" \
      --assignee "@me" >/dev/null
    echo "  ✅ PR created"
  fi
}

if [[ -n "$TARGET" ]]; then
  targets=$(jq --arg r "$TARGET" -c '.targets[] | select(.repo == $r)' <<<"$TARGETS_JSON")
else
  targets=$(jq -c '.targets[]' <<<"$TARGETS_JSON")
fi

if [[ -z "$targets" ]]; then
  echo "No targets matched."
  exit 1
fi

while IFS= read -r t; do
  repo=$(jq -r '.repo' <<<"$t")
  files=$(jq -c '.files' <<<"$t")
  process_target "$repo" "$files" || echo "  ⚠️  target failed (continuing)"
done <<< "$targets"

echo
echo "Done. Mode: $MODE"
