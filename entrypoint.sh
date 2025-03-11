#!/bin/bash

set -e
if [[ -n "$DEBUG" ]]; then
    set -x
fi

# Default to the repository root if CHARTS_DIR is not set
CHARTS_DIR=${CHARTS_DIR:-.}
CHART_REPOSITORY=${CHART_REPOSITORY:-""}

lookup_latest_tag() {
    git fetch --tags > /dev/null 2>&1
    if ! git describe --tags --abbrev=0 2> /dev/null; then
        git rev-list --max-parents=0 --first-parent HEAD
    fi
}

filter_charts() {
    while read -r chart; do
        # When chart is the root, use Chart.yaml directly
        if [[ "$chart" == "." ]]; then
            file="Chart.yaml"
        else
            file="$chart/Chart.yaml"
        fi
        if [[ -f "$file" ]]; then
            echo "$chart"
        else
            echo "WARNING: $file is missing, assuming that '$chart' is not a Helm chart. Skipping." 1>&2
        fi
    done
}

lookup_chart_changes() {
    local commit=$1
    local charts_dir=$2
    local changed_files
    changed_files=$(git diff --find-renames --name-only "$commit" -- "$charts_dir")
    local depth=$(( $(tr "/" "\n" <<< "$charts_dir" | sed '/^\(\.\)*$/d' | wc -l) + 1 ))
    local fields="1-${depth}"
    cut -d '/' -f "$fields" <<< "$changed_files" | uniq | filter_charts
}

package_chart() {
    local charts=$1
    for chart in $charts; do
        echo "Packaging chart '$chart'..."
        helm package "$chart" --dependency-update --destination $chart_destination_dir
    done
}

create_git_tag_from_chart() {
    local charts=$1
    for chart in $charts; do
        chart_version=$(echo $chart | sed -e 's+.tgz++g')
        echo "Creating tag $chart_version..."
        git tag $chart_version
        git push origin $chart_version
    done
}

# Iterate over all built charts and push them to the chart repository
push_chart() {
    local charts=$1
    for chart in $charts; do
        echo "Pushing chart '$chart'..."
        helm push ${chart_destination_dir}/$chart $CHART_REPOSITORY
    done
}

# Check if required environment variables are set
if [[ -z "$CHART_REPOSITORY" ]]; then
    echo "CHART_REPOSITORY is not set"
    exit 1
fi
if [[ -z "$CHARTS_DIR" ]]; then
    echo "CHARTS_DIR is not set"
    exit 1
fi

# Directory where the packaged charts will be stored
chart_destination_dir="builds"
mkdir -p ${chart_destination_dir}

# The last tag that was created (used to determine which charts have changed)
lastTag=$(lookup_latest_tag)

# chart_diffs is a list of charts that have changed since the last release
chart_diffs=$(lookup_chart_changes "$lastTag" "${CHARTS_DIR}")

# Package the changed charts
package_chart "$chart_diffs"

ls -l $chart_destination_dir

echo "Checking if there are charts to push"
if [[ ! -d ${chart_destination_dir} ]]; then
    echo "No charts to push"
    exit 0
fi

# Create a tag for each chart and push to the chart repository
create_git_tag_from_chart "$(ls $chart_destination_dir)"
push_chart "$(ls $chart_destination_dir)"

# Cleanup
rm -rf $chart_destination_dir
