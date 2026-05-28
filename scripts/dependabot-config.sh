#!/usr/bin/env bash

set -euo pipefail

BOT_OWNER="${BOT_OWNER:-shravangoswami-bot}"
OPERATION="${OPERATION:-update}"
TARGET="${TARGET:-inventory}"
REMOVE_COMPATHELPER="${REMOVE_COMPATHELPER:-true}"
UPDATE_DEPENDABOT="${UPDATE_DEPENDABOT:-true}"
BRANCH="${BRANCH:-dependabot-config}"
DRY_RUN="${DRY_RUN:-true}"
INVENTORY_PATH="${INVENTORY_PATH:-repo-inventory.yml}"
COMMIT_CO_AUTHOR="${COMMIT_CO_AUTHOR:-shravanngoswamii <shravanngoswamii@users.noreply.github.com>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GENERATOR="${SCRIPT_DIR}/generate-dependabot.mjs"
PR_BODY_RENDERER="${SCRIPT_DIR}/render-pr-body.mjs"
PR_BODY_TEMPLATE="${PR_BODY_TEMPLATE:-${REPO_DIR}/pr-body.md.template}"

if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "error: GH_TOKEN is required" >&2
    exit 1
fi

bool_is_true() {
    [[ "${1,,}" == "true" ]]
}

repo_short_name() {
    local repo="$1"
    echo "${repo##*/}"
}

repo_full_name() {
    local repo="$1"
    setting_value "$repo" repo
}

fork_full_name() {
    local repo="$1"
    echo "${BOT_OWNER}/$(repo_short_name "$repo")"
}

workflow_run_url() {
    if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
        echo "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    fi
}

inventory_repos() {
    node "$GENERATOR" --inventory "$INVENTORY_PATH" --list-repos
}

target_repos() {
    case "$TARGET" in
        inventory)
            inventory_repos
            ;;
        *)
            echo "$TARGET"
            ;;
    esac
}

setting_value() {
    local repo="$1"
    local key="$2"
    node "$GENERATOR" --inventory "$INVENTORY_PATH" --describe "$repo" \
        | awk -F= -v key="$key" '$1 == key { print $2 }'
}

append_change() {
    local changes_file="$1"
    local condition="$2"
    local message="$3"

    if bool_is_true "$condition"; then
        echo "- ${message}" >> "$changes_file"
    fi
}

ensure_fork() {
    local upstream_repo="$1"
    local fork_repo="$2"

    if gh repo view "$fork_repo" >/dev/null 2>&1; then
        echo "Fork exists: ${fork_repo}"
        return
    fi

    if bool_is_true "$DRY_RUN"; then
        echo "DRY RUN: would fork ${upstream_repo} to ${fork_repo}."
        return
    fi

    echo "Creating fork ${fork_repo} from ${upstream_repo}"
    gh repo fork "$upstream_repo" --clone=false --default-branch-only
}

detect_file_state() {
    local repo_dir="$1"
    COMPATHELPER_BEFORE="missing"
    DEPENDABOT_BEFORE="missing"
    EXISTING_DEPENDABOT_PATH=""

    if [[ -f "${repo_dir}/.github/workflows/CompatHelper.yml" || -f "${repo_dir}/.github/workflows/CompatHelper.yaml" ]]; then
        COMPATHELPER_BEFORE="present"
    fi

    if [[ -f "${repo_dir}/.github/dependabot.yml" ]]; then
        DEPENDABOT_BEFORE="present"
        EXISTING_DEPENDABOT_PATH=".github/dependabot.yml"
    elif [[ -f "${repo_dir}/.github/dependabot.yaml" ]]; then
        DEPENDABOT_BEFORE="present"
        EXISTING_DEPENDABOT_PATH=".github/dependabot.yaml"
    fi
}

pr_title() {
    local compat_removed="$1"
    local dependabot_added="$2"
    local dependabot_updated="$3"

    if bool_is_true "$compat_removed" && bool_is_true "$dependabot_added"; then
        echo "Replace CompatHelper with Dependabot"
    elif bool_is_true "$compat_removed" && bool_is_true "$dependabot_updated"; then
        echo "Remove CompatHelper and update Dependabot config"
    elif bool_is_true "$dependabot_added"; then
        echo "Add Dependabot config"
    elif bool_is_true "$dependabot_updated"; then
        echo "Update Dependabot config"
    elif bool_is_true "$compat_removed"; then
        echo "Remove CompatHelper workflow"
    else
        echo "Update Dependabot config"
    fi
}

write_pr_body() {
    local body_file="$1"
    local compat_removed="$2"
    local dependabot_added="$3"
    local dependabot_updated="$4"
    local normalized_yaml="$5"
    local julia_directories="$6"
    local julia_group_all="$7"
    local npm_directories="$8"
    local npm_enabled="$9"
    local npm_group_all="${10}"
    local cargo_directories="${11}"
    local cargo_enabled="${12}"
    local cargo_group_all="${13}"
    local changes_file
    local changes_made

    changes_file="${body_file}.changes"
    : > "$changes_file"
    append_change "$changes_file" "$compat_removed" "Removed CompatHelper workflow."
    append_change "$changes_file" "$dependabot_added" "Added Dependabot config."
    append_change "$changes_file" "$dependabot_updated" "Updated Dependabot config."
    append_change "$changes_file" "$normalized_yaml" "Normalized \`.github/dependabot.yaml\` to \`.github/dependabot.yml\`."
    changes_made="$(cat "$changes_file")"

    AUTOMATION_REPO="${GITHUB_REPOSITORY:-shravangoswami-bot/dependabot-config-bot}" \
        WORKFLOW_RUN_URL="$(workflow_run_url)" \
        COMPATHELPER_BEFORE="$COMPATHELPER_BEFORE" \
        DEPENDABOT_BEFORE="$DEPENDABOT_BEFORE" \
        EXISTING_DEPENDABOT_PATH="$EXISTING_DEPENDABOT_PATH" \
        JULIA_DIRECTORIES="$julia_directories" \
        NPM_DIRECTORIES="$npm_directories" \
        NPM_ENABLED="$npm_enabled" \
        CARGO_DIRECTORIES="$cargo_directories" \
        CARGO_ENABLED="$cargo_enabled" \
        CHANGES_MADE="$changes_made" \
        node "$PR_BODY_RENDERER" "$PR_BODY_TEMPLATE" "$body_file"
}

dry_run_repo() {
    local repo="$1"
    local full_repo
    local fork_repo
    local npm_directories
    local cargo_directories

    full_repo="$(repo_full_name "$repo")"
    fork_repo="$(fork_full_name "$repo")"
    npm_directories="$(setting_value "$repo" npm_directories)"
    cargo_directories="$(setting_value "$repo" cargo_directories)"

    echo
    echo "DRY RUN: ${full_repo}"
    echo "  fork repo: ${fork_repo}"
    echo "  branch: ${BRANCH}"
    echo "  remove CompatHelper: ${REMOVE_COMPATHELPER}"
    echo "  update Dependabot: ${UPDATE_DEPENDABOT}"
    echo "  Julia directories: $(setting_value "$repo" julia_directories)"
    echo "  npm directories: ${npm_directories:-none}"
    echo "  Cargo directories: ${cargo_directories:-none}"
}

dry_run_cleanup_repo() {
    local repo="$1"
    local upstream_repo
    local fork_repo

    upstream_repo="$(repo_full_name "$repo")"
    fork_repo="$(fork_full_name "$repo")"

    echo
    echo "DRY RUN CLEANUP: ${upstream_repo}"
    echo "  would close open PRs with head ${BOT_OWNER}:${BRANCH}"
    echo "  would delete branch ${BRANCH} from ${fork_repo}"
}

process_repo() {
    local repo="$1"
    local short_repo
    local upstream_repo
    local fork_repo
    local default_branch
    local repo_dir
    local fork_url
    local compat_removed="false"
    local dependabot_added="false"
    local dependabot_updated="false"
    local normalized_yaml="false"
    local generated_dependabot
    local title
    local body_file
    local existing_pr

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
    git -C "$repo_dir" checkout "$default_branch"
    git -C "$repo_dir" checkout -B "$BRANCH" "origin/${default_branch}"

    detect_file_state "$repo_dir"

    if bool_is_true "$REMOVE_COMPATHELPER"; then
        rm -f "${repo_dir}/.github/workflows/CompatHelper.yml" "${repo_dir}/.github/workflows/CompatHelper.yaml"
        if [[ "$COMPATHELPER_BEFORE" == "present" ]]; then
            compat_removed="true"
        fi
    fi

    if bool_is_true "$UPDATE_DEPENDABOT"; then
        mkdir -p "${repo_dir}/.github"
        generated_dependabot="${WORKDIR}/${short_repo}-dependabot.yml"
        node "$GENERATOR" --inventory "$INVENTORY_PATH" "$short_repo" > "$generated_dependabot"

        if [[ "$DEPENDABOT_BEFORE" == "missing" ]]; then
            dependabot_added="true"
        elif [[ -f "${repo_dir}/.github/dependabot.yml" ]] && ! cmp -s "$generated_dependabot" "${repo_dir}/.github/dependabot.yml"; then
            dependabot_updated="true"
        elif [[ -f "${repo_dir}/.github/dependabot.yaml" ]] && ! cmp -s "$generated_dependabot" "${repo_dir}/.github/dependabot.yaml"; then
            dependabot_updated="true"
        fi

        if [[ -f "${repo_dir}/.github/dependabot.yaml" ]]; then
            rm "${repo_dir}/.github/dependabot.yaml"
            normalized_yaml="true"
            dependabot_updated="true"
        fi
        cp "$generated_dependabot" "${repo_dir}/.github/dependabot.yml"
    fi

    if git -C "$repo_dir" diff --quiet --exit-code; then
        echo "No changes required for ${upstream_repo}; skipping PR."
        return
    fi

    title="$(pr_title "$compat_removed" "$dependabot_added" "$dependabot_updated")"
    body_file="${WORKDIR}/${short_repo}-pr-body.md"
    write_pr_body \
        "$body_file" \
        "$compat_removed" \
        "$dependabot_added" \
        "$dependabot_updated" \
        "$normalized_yaml" \
        "$(setting_value "$short_repo" julia_directories)" \
        "$(setting_value "$short_repo" julia_group_all)" \
        "$(setting_value "$short_repo" npm_directories)" \
        "$(setting_value "$short_repo" npm_enabled)" \
        "$(setting_value "$short_repo" npm_group_all)" \
        "$(setting_value "$short_repo" cargo_directories)" \
        "$(setting_value "$short_repo" cargo_enabled)" \
        "$(setting_value "$short_repo" cargo_group_all)"

    git -C "$repo_dir" add .github
    git -C "$repo_dir" commit -m "$title" -m "Co-authored-by: ${COMMIT_CO_AUTHOR}"
    git -c http.https://github.com/.extraheader= -c credential.helper= -C "$repo_dir" push --force fork "$BRANCH"

    existing_pr="$(gh pr list --repo "$upstream_repo" --search "head:${BOT_OWNER}:${BRANCH}" --state open --json url -q '.[0].url')"
    if [[ -n "$existing_pr" ]]; then
        echo "PR already exists: ${existing_pr}"
        echo "Updating PR title and body..."
        gh pr edit "$existing_pr" \
            --repo "$upstream_repo" \
            --title "$title" \
            --body-file "$body_file"
    else
        gh pr create \
            --repo "$upstream_repo" \
            --base "$default_branch" \
            --head "${BOT_OWNER}:${BRANCH}" \
            --title "$title" \
            --body-file "$body_file"
    fi
}

cleanup_repo() {
    local repo="$1"
    local upstream_repo
    local fork_repo
    local fork_url
    local pr_numbers
    local pr_number

    upstream_repo="$(repo_full_name "$repo")"
    fork_repo="$(fork_full_name "$repo")"
    fork_url="https://x-access-token:${GH_TOKEN}@github.com/${fork_repo}.git"

    echo
    echo "==> Cleaning up ${upstream_repo}"

    mapfile -t pr_numbers < <(
        gh pr list \
            --repo "$upstream_repo" \
            --search "head:${BOT_OWNER}:${BRANCH}" \
            --state open \
            --json number \
            -q '.[].number'
    )

    for pr_number in "${pr_numbers[@]}"; do
        if bool_is_true "$DRY_RUN"; then
            echo "DRY RUN: would close PR #${pr_number} in ${upstream_repo}."
        else
            gh pr close "$pr_number" --repo "$upstream_repo" --comment "Closing this automated Dependabot config PR via workflow dispatch."
        fi
    done

    if git -c http.https://github.com/.extraheader= -c credential.helper= ls-remote --exit-code --heads "$fork_url" "$BRANCH" >/dev/null 2>&1; then
        if bool_is_true "$DRY_RUN"; then
            echo "DRY RUN: would delete branch ${BRANCH} in ${fork_repo}."
        else
            git -c http.https://github.com/.extraheader= -c credential.helper= push "$fork_url" --delete "$BRANCH"
        fi
    else
        echo "Branch ${BRANCH} does not exist in ${fork_repo}."
    fi
}

main() {
    local repos

    case "$OPERATION" in
        update|cleanup)
            ;;
        *)
            echo "error: OPERATION must be update or cleanup." >&2
            exit 2
            ;;
    esac

    if [[ "$TARGET" == "all" ]]; then
        echo "error: TARGET=all is not supported. Use TARGET=inventory or a single repo name." >&2
        exit 2
    fi

    mapfile -t repos < <(target_repos)

    if [[ "${#repos[@]}" -eq 0 ]]; then
        echo "No target repositories found for TARGET=${TARGET}."
        exit 0
    fi

    if bool_is_true "$DRY_RUN"; then
        for repo in "${repos[@]}"; do
            if [[ "$OPERATION" == "cleanup" ]]; then
                dry_run_cleanup_repo "$repo"
            else
                dry_run_repo "$repo"
            fi
        done
        exit 0
    fi

    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT

    for repo in "${repos[@]}"; do
        if [[ "$OPERATION" == "cleanup" ]]; then
            cleanup_repo "$repo"
        else
            process_repo "$repo"
        fi
    done
}

main "$@"
