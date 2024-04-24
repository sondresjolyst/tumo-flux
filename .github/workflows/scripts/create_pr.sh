#!/usr/bin/env bash

function create-pr() {
    if [[ -z "${PR_BRANCH}" ]]; then
        PR_BRANCH="flux-image-updates"
    fi

    if [[ -z "${PR_NAME}" ]]; then
        PR_NAME="Automatic Pull Request"
    fi

    if [[ $(git fetch origin && git branch --remotes) == *"origin/${PR_BRANCH}"* ]]; then
        git switch "${PR_BRANCH}"
        git pull
        PR_STATE=$(gh pr view "${PR_BRANCH}" --json state --jq '.state')
    else
        PR_STATE="NONEXISTENT"
    fi

    if [[ "${PR_STATE}" != "OPEN" ]]; then
        echo "Create PR"
        gh pr create --title "${PR_NAME}" --base master --body "**Automatic Pull Request**"
    fi
}

create-pr 0
