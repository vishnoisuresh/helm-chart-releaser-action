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

# Check if Chart.yaml exists in the repository root
check_root_chart() {
    if [[ -f "Chart.yaml" ]]; then
        echo "Found Chart.yaml at repository root"
        echo "."
        return 0
    fi
    return 1
}

filter_charts() {
    while read -r chart; do
        # Skip empty lines
        if [[ -z "$chart" ]]; then
            continue
        fi
        
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
    
    # First check if there's a Chart.yaml at the root
    if check_root_chart; then
        return
    fi
    
    # If not at the root, look for changes in subdirectories
    local changed_files
    changed_files=$(git diff --find-renames --name-only "$commit" -- "$charts_dir")
    
    # Check if Chart.yaml itself has changed
    if echo "$changed_files" | grep -q "^Chart.yaml$"; then
        echo "."
        return
    fi
    
    # Process other changes
    local depth=$(( $(tr "/" "\n" <<< "$charts_dir" | sed '/^\(\.\)*$/d' | wc -l) + 1 ))
    local fields="1-${depth}"
    cut -d '/' -f "$fields" <<< "$changed_files" | uniq | filter_charts
}

package_chart() {
    local charts=$1
    
    # If no charts specified but Chart.yaml exists at root, package root
    if [[ -z "$charts" ]] && [[ -f "Chart.yaml" ]]; then
        echo "No specific charts changed, but found Chart.yaml at root. Packaging root chart..."
        helm package "." --dependency-update --destination $chart_destination_dir
        return
    fi
    
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

# Directory where the packaged charts will be stored
chart_destination_dir="builds"
mkdir -p ${chart_destination_dir}

# Debug information
echo "Current directory: $(pwd)"
echo "Contents of current directory:"
ls -la

# Check for Chart.yaml at root explicitly
if [[ -f "Chart.yaml" ]]; then
    echo "Found Chart.yaml at root. This is a root-level Helm chart."
    ROOT_CHART=true
else
    echo "No Chart.yaml found at root."
    ROOT_CHART=false
fi

# The last tag that was created (used to determine which charts have changed)
lastTag=$(lookup_latest_tag)
echo "Last tag: $lastTag"

# For root chart, simplify the process
if [[ "$ROOT_CHART" == "true" ]]; then
    echo "Processing root chart..."
    helm package "." --dependency-update --destination $chart_destination_dir
else
    # chart_diffs is a list of charts that have changed since the last release
    chart_diffs=$(lookup_chart_changes "$lastTag" "${CHARTS_DIR}")
    echo "Changed charts: $chart_diffs"

    # Package the changed charts
    package_chart "$chart_diffs"
fi

echo "Contents of build directory:"
ls -l $chart_destination_dir

# Check if there are charts to push
if [[ -z "$(ls -A $chart_destination_dir)" ]]; then
    echo "No charts to push"
    exit 0
fi

# Create a tag for each chart and push to the chart repository
create_git_tag_from_chart "$(ls $chart_destination_dir)"
push_chart "$(ls $chart_destination_dir)"

# Cleanup
rm -rf $chart_destination_dir