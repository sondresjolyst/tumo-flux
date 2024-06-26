#!/usr/bin/env bash

if [[ -z "${PR_BRANCH}" ]]; then
    PR_BRANCH="flux-image-updates"
fi

if [[ -z "${SOURCE_CLUSTER}" ]]; then
    SOURCE_CLUSTER="production"
fi

if [[ -z "${DESTINATION_CLUSTER}" ]]; then
    DESTINATION_CLUSTER="production"
fi

numberOfChanges=0

function get_version() {
    local push=false
    git config --global user.name 'github-actions[bot]'
    git config --global user.email '41898282+github-actions[bot]@users.noreply.github.com'
    git fetch
    git checkout -t "origin/${PR_BRANCH}" -b "${PR_BRANCH}" || git checkout -b "${PR_BRANCH}"

    while read -r entry; do
        local file=$(echo ${entry} | awk '{split($1,a,":"); print a[1]}')
        local line=$(echo ${entry} | awk '{split($1,a,":"); print a[2]}')
        local current=$(echo ${entry} | awk '{print $3}')
        local repo=$(echo ${entry} | grep -Eo 'https://[^ >]+' | sed 's/\/releases.*$//' | awk '{n=split($1,a,"/"); print a[n-1]"/"a[n]}')
        local package_name=${repo##*/}

        if [[ "${current}" ]]; then
            if [[ "${SOURCE_CLUSTER}" == "${DESTINATION_CLUSTER}" ]]; then
                # Get version from ArtifactHub
                newest=$(curl "https://artifacthub.io/api/v1/packages/helm/${repo}" \
                    --request "GET" \
                    --header "accept: application/json" \
                    --silent |
                    jq -er '.version // empty' ||
                    # Try GitHub
                    curl "https://api.github.com/repos/${repo}/tags" \
                        --request "GET" \
                        --header "Accept: application/vnd.github.v3+json" \
                        --silent |
                    jq -er '.[0].name // empty') || {
                    echo "Version for $package_name not found. $current"
                    continue
                }
            else
                # Update versions in destination cluster with versions in source cluster
                newest="${current}"
                file=$(echo ${file} | sed 's/'${SOURCE_CLUSTER}'/'${DESTINATION_CLUSTER}'/')
                if [[ -f "${file}" ]]; then
                    current=$(grep "${repo}" "${file}" | awk '{print $2}')
                fi
            fi

            if [[ "${newest}" == *beta* || "${newest}" == *alpha* || "${newest}" == *rc* ]]; then
                printf "Skipping %s for %s - Current %s\n" "${newest}" "${package_name}" "${current}"
                continue
            fi

            # Compare versions
            if [[ "${current}" && "${newest}" && "${current}" != "${newest}" ]]; then
                # Update file, create branch and commit change
                printf "New version for %s available: %s -> %s\n" "${package_name}" "${current}" "${newest}"
                find="$(echo ${entry} | awk '{print $2}') ${current}"
                replace="$(echo ${entry} | awk '{print $2}') ${newest}"
                sed -i "s/${find}/${replace}/" "${file}"
                git add "${file}"
                git commit -m "Update ${package_name} from ${current} to ${newest}"
                push=true
            else
                printf "No new version available for %s - Current %s\n" "${package_name}" "${current}"
            fi
        else
            printf "Could not find package version locally."
        fi
    done < <(grep -rn -E 'artifacthub.io|github.com' ${GITHUB_WORKSPACE}'/clusters/'${SOURCE_CLUSTER} --exclude-dir 'flux-system' | grep -v -e "tag:")

    if [[ "${push}" == true ]]; then
        echo "push"
        git push --set-upstream origin "${PR_BRANCH}"
        numberOfChanges=$((numberOfChanges + 1))
    fi
}

get_version
if [[ -n $CI ]]; then
    echo "numberOfChanges=$numberOfChanges" >>$GITHUB_OUTPUT
fi
