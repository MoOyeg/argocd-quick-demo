#!/usr/bin/env bash
# Replace the __REPO_URL__ / __TARGET_REVISION__ placeholders with your fork.
# Argo CD pulls manifests from git, not from your laptop, so every Application
# has to point at a URL the cluster can actually reach.
#
#   ./scripts/set-repo.sh https://github.com/you/argocd-quick-demo.git [branch]
set -euo pipefail

REPO_URL="${1:-}"
TARGET_REVISION="${2:-main}"

if [[ -z "$REPO_URL" ]]; then
  echo "usage: $0 <git-repo-url> [branch]" >&2
  echo "example: $0 https://github.com/you/argocd-quick-demo.git main" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

# Escape slashes for sed.
esc_url=${REPO_URL//\//\\/}
esc_rev=${TARGET_REVISION//\//\\/}

files=$(grep -rl -e '__REPO_URL__' -e '__TARGET_REVISION__' --include='*.yaml' . || true)

if [[ -z "$files" ]]; then
  echo "No placeholders left - already pointed at a repo."
  grep -rh 'repoURL:' --include='*.yaml' . | sort -u
  exit 0
fi

echo "$files" | while read -r f; do
  sed -i "s/__REPO_URL__/${esc_url}/g; s/__TARGET_REVISION__/${esc_rev}/g" "$f"
  echo "  updated $f"
done

echo
echo "repoURL        = $REPO_URL"
echo "targetRevision = $TARGET_REVISION"

case "$TARGET_REVISION" in
  main|master|develop|trunk)
    cat <<'WARN'

  NOTE: you are tracking a branch.
  The article's "Version manifests" practice says to deploy a git tag or a
  commit SHA instead. A branch moves under you: Argo CD will pick up whatever
  lands on it next, and a re-sync months from now will not deploy what you
  tested. Fine for driving this demo; not what you want in an environment
  you care about.

    git tag -a v1.0.0 -m "demo v1.0.0" && git push origin v1.0.0
    ./scripts/set-repo.sh <repo-url> v1.0.0
WARN
    ;;
esac

echo
echo "Commit and push these changes before syncing - Argo CD reads the repo,"
echo "not your working copy."
