#!/usr/bin/env bash

set -euo pipefail

BOT_OWNER="${BOT_OWNER:-shravangoswami-bot}"
TARGET="${TARGET:-inventory}"
BRANCH="${BRANCH:-patch-codecov-dependabot}"
DRY_RUN="${DRY_RUN:-true}"
INVENTORY_PATH="${INVENTORY_PATH:-repo-inventory.yml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="${SCRIPT_DIR}/generate-dependabot.mjs"
PATCHER="${SCRIPT_DIR}/patch-codecov.mjs"

PR_TITLE="skip codecov upload on Dependabot PRs"
PR_BODY="Dependabot PRs run in a sandboxed environment without access to repository secrets, so \`CODECOV_TOKEN\` is unavailable and the codecov upload fails with:

\`\`\`
Upload queued for processing failed: {\"message\":\"Token required because branch is protected\"}
\`\`\`

This adds \`if: github.actor != 'dependabot[bot]'\` to each \`codecov/codecov-action\` step so the upload is skipped for Dependabot PRs. No coverage changes are expected from dependency bumps, so this is safe.

Automated by [dependabot-config-bot](https://github.com/${BOT_OWNER}/dependabot-config-bot)."

if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "error: GH_TOKEN is required" >&2
    exit 1
fi

bool_is_true() {
    [[ "${1,,}" == "true" ]]
}

repo_short_name() {
    echo "${1##*/}"
}

repo_full_name() {
    node "$GENERATOR" --inventory "$INVENTORY_PATH" --describe "$1" \
        | awk -F= '$1 == "repo" { print $2 }'
}

fork_full_name() {
    echo "${BOT_OWNER}/$(repo_short_name "$1")"
}

inventory_repos() {
    node "$GENERATOR" --inventory "$INVENTORY_PATH" --list-repos
}

target_repos() {
    case "$TARGET" in
        inventory) inventory_repos ;;
        *) echo "$TARGET" ;;
    esac
}

ensure_fork() {
    local upstream_repo="$1"
    local fork_repo="$2"

    if gh repo view "$fork_repo" >/dev/null 2>&1; then
        return
    fi

    echo "Creating fork ${fork_repo} from ${upstream_repo}"
    gh repo fork "$upstream_repo" --clone=false --default-branch-only
}

process_repo() {
    local repo="$1"
    local short_repo upstream_repo fork_repo default_branch repo_dir fork_url changed_files

    short_repo="$(repo_short_name "$repo")"
    upstream_repo="$(repo_full_name "$repo")"
    fork_repo="$(fork_full_name "$repo")"
    fork_url="https://x-access-token:${GH_TOKEN}@github.com/${fork_repo}.git"

    echo
    echo "==> Processing ${upstream_repo}"

    default_branch="$(gh repo view "$upstream_repo" --json defaultBranchRef -q '.defaultBranchRef.name')"
    ensure_fork "$upstream_repo" "$fork_repo"

    repo_dir="${WORKDIR}/${short_repo}"
    gh repo clone "$upstream_repo" "$repo_dir"
    git -C "$repo_dir" remote add fork "$fork_url"
    git -C "$repo_dir" checkout -B "$BRANCH" "origin/${default_branch}"

    if ! changed_files="$(node "$PATCHER" "$repo_dir")"; then
        echo "No codecov steps to patch in ${upstream_repo}; skipping."
        return
    fi

    echo "Patched:"
    echo "$changed_files" | sed 's/^/  /'

    git -C "$repo_dir" add .github/workflows
    git -C "$repo_dir" commit -m "$PR_TITLE"
    git -c http.https://github.com/.extraheader= -c credential.helper= \
        -C "$repo_dir" push --force fork "$BRANCH"

    local existing_pr
    existing_pr="$(gh pr list --repo "$upstream_repo" --head "${BOT_OWNER}:${BRANCH}" \
        --state open --json url -q '.[0].url')"

    if [[ -n "$existing_pr" ]]; then
        echo "Updating existing PR: ${existing_pr}"
        gh pr edit "$existing_pr" --repo "$upstream_repo" \
            --title "$PR_TITLE" --body "$PR_BODY"
    else
        gh pr create \
            --repo "$upstream_repo" \
            --base "$default_branch" \
            --head "${BOT_OWNER}:${BRANCH}" \
            --title "$PR_TITLE" \
            --body "$PR_BODY"
    fi
}

dry_run_repo() {
    local repo="$1"
    local upstream_repo fork_repo

    upstream_repo="$(repo_full_name "$repo")"
    fork_repo="$(fork_full_name "$repo")"

    echo
    echo "DRY RUN: ${upstream_repo}"
    echo "  fork:   ${fork_repo}"
    echo "  branch: ${BRANCH}"
}

main() {
    mapfile -t repos < <(target_repos)

    if [[ "${#repos[@]}" -eq 0 ]]; then
        echo "No target repositories found for TARGET=${TARGET}."
        exit 0
    fi

    if bool_is_true "$DRY_RUN"; then
        for repo in "${repos[@]}"; do
            dry_run_repo "$repo"
        done
        exit 0
    fi

    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT

    for repo in "${repos[@]}"; do
        process_repo "$repo"
    done
}

main "$@"
