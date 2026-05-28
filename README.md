# Dependabot config bot

This repository opens Dependabot configuration PRs from `shravangoswami-bot` forks into TuringLang repositories.

## Workflow

Run `Dependabot config` manually with:

- `operation=update` to open or update PRs
- `operation=cleanup` to close matching PRs and delete bot fork branches
- `target=inventory` to use `repo-inventory.yml`
- `target=RepoName.jl` to run one repository

## Inventory

Repository settings live in `repo-inventory.yml`.
The generated Dependabot file uses `dependabot.yml.ejs`.
