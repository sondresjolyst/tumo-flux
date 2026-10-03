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

            # Reject version strings that are not a plain tag. The value is
            # fed to the file rewrite below; anything with shell or sed
            # metacharacters must never reach it.
            if ! [[ "${newest}" =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]*$ ]]; then
                printf "Skipping %s - unexpected version string: %s\n" "${package_name}" "${newest}"
                continue
            fi

            # Compare versions
            if [[ "${current}" && "${newest}" && "${current}" != "${newest}" ]]; then
                # Update file, create branch and commit change
                printf "New version for %s available: %s -> %s\n" "${package_name}" "${current}" "${newest}"
                find="$(echo ${entry} | awk '{print $2}') ${current}"
                replace="$(echo ${entry} | awk '{print $2}') ${newest}"
                # Replace the value on its own line only, treating both the old
                # and new strings as literal data (index/substr, not a regex),
                # so a crafted version string cannot inject sed or shell code.
                tmp=$(mktemp)
                old="${find}" new="${replace}" ln="${line}" awk '
                    NR==(ENVIRON["ln"]+0) {
                        o=ENVIRON["old"]; n=ENVIRON["new"]
                        i=index($0, o)
                        if (i>0) $0=substr($0,1,i-1) n substr($0, i+length(o))
                    }
                    { print }
                ' "${file}" > "${tmp}" && mv "${tmp}" "${file}"
                git add "${file}"
                git commit -m "chore(${SOURCE_CLUSTER}): update ${package_name} from ${current} to ${newest}"
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
