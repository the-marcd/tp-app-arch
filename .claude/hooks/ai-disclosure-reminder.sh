#!/usr/bin/env bash
# PostToolUse hook (Write|Edit): if a file in this repo is not yet catalogued in
# AI_DISCLOSURE.md, inject a reminder into Claude's context.
#
# Silent for: AI_DISCLOSURE.md itself, .claude/, .git/, gitignored files, and any
# path already named in the catalogue — so it only speaks up when there is a real
# gap. Exits 0 in every case; this is a reminder, not a gate.
set -uo pipefail

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_response.filePath // .tool_input.file_path // empty')
[ -n "$file" ] || exit 0

repo="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$repo" ]; then
  repo=$(git -C "$(dirname -- "$file")" rev-parse --show-toplevel 2>/dev/null) || exit 0
fi

disclosure="$repo/AI_DISCLOSURE.md"
[ -f "$disclosure" ] || exit 0

case "$file" in
  "$repo"/*) ;;
  *) exit 0 ;;
esac

rel="${file#"$repo"/}"
case "$rel" in
  AI_DISCLOSURE.md | .claude/* | .git/*) exit 0 ;;
esac

git -C "$repo" check-ignore -q -- "$file" && exit 0
grep -qF -- "$rel" "$disclosure" && exit 0

jq -cn --arg rel "$rel" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("AI_DISCLOSURE.md does not list \($rel). This repo catalogues every AI-authored file: before ending this turn, add \($rel) to the file table and write its per-file summary.")
  }
}'
