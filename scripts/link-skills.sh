#!/usr/bin/env bash
# Symlink every skill in this repo into the local Claude Code skills directory,
# so a git pull keeps installed skills current.
#   ./scripts/link-skills.sh [target-dir]   (default: ~/.claude/skills)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${1:-$HOME/.claude/skills}"
mkdir -p "$target"

count=0
for skill_dir in "$repo_root"/plugins/*/skills/*/; do
  [ -f "${skill_dir}SKILL.md" ] || continue
  name="$(basename "$skill_dir")"
  link="$target/$name"

  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "skip  $name — $link exists and is not a symlink" >&2
    continue
  fi

  ln -sfn "${skill_dir%/}" "$link"
  echo "link  $name -> $link"
  count=$((count + 1))
done

echo "$count skill(s) linked into $target"
