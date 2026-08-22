#!/bin/bash

set -euo pipefail

# Configuration
ORGANIZATION="freeipa"
PROJECT="freeipa"
DEFINITION_ID="3"
BASE_URL="https://dev.azure.com"
API_VERSION="7.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    echo "Usage: $0 [-f] <PR_NUMBER>"
    echo "Example: $0 8540"
    echo "Example: $0 -f 8540"
    echo ""
    echo "Options:"
    echo "  -f    Only download logs for failed jobs"
    exit 1
}

FAILED_ONLY=false

# Parse options
while getopts "f" opt; do
    case $opt in
        f)
            FAILED_ONLY=true
            ;;
        *)
            usage
            ;;
    esac
done

# Shift to get positional arguments
shift $((OPTIND - 1))

if [[ $# -ne 1 ]]; then
    usage
fi

PR_NUMBER="$1"
ARTIFACT_DIR="./artifacts/pr-${PR_NUMBER}"

echo -e "${BLUE}Searching for builds associated with PR #${PR_NUMBER}...${NC}"

# Search for the most recent build for this PR
# Azure uses pull/{PR}/merge format for PR branches
BUILD_LIST=$(curl -s "${BASE_URL}/${ORGANIZATION}/${PROJECT}/_apis/build/builds?definitions=${DEFINITION_ID}&statusFilter=completed&api-version=${API_VERSION}")

# Parse the JSON to find builds with matching PR, sorted by finish time (most recent first)
BUILD_ID=$(echo "$BUILD_LIST" | jq -r ".value[] | select(.sourceBranch | contains(\"pull/${PR_NUMBER}\")) | {id: .id, finishTime: .finishTime}" | jq -s 'sort_by(.finishTime) | reverse | .[0].id')

if [[ -z "$BUILD_ID" || "$BUILD_ID" == "null" ]]; then
    echo -e "${RED}Error: No builds found for PR #${PR_NUMBER}${NC}"
    exit 1
fi
echo -e "${GREEN}Found build ID: ${BUILD_ID}${NC}"

# Get build details
BUILD_DETAIL=$(curl -s "${BASE_URL}/${ORGANIZATION}/${PROJECT}/_apis/build/builds/${BUILD_ID}?api-version=${API_VERSION}")
BUILD_STATUS=$(echo "$BUILD_DETAIL" | jq -r '.status')
BUILD_RESULT=$(echo "$BUILD_DETAIL" | jq -r '.result')
BUILD_URL=$(echo "$BUILD_DETAIL" | jq -r '.url')

echo -e "${BLUE}Build Details:${NC}"
echo "  Status: ${BUILD_STATUS}"
echo "  Result: ${BUILD_RESULT}"
echo "  URL: ${BUILD_URL}"

if [[ "$FAILED_ONLY" == true ]]; then
    echo -e "${BLUE}Mode: Downloading logs for failed jobs only${NC}"
fi

if [[ "$FAILED_ONLY" == true ]]; then
    # Get timeline to find failed jobs
    echo -e "${BLUE}Fetching build timeline to identify failed jobs...${NC}"
    TIMELINE=$(curl -s "${BASE_URL}/${ORGANIZATION}/${PROJECT}/_apis/build/builds/${BUILD_ID}/timeline?api-version=${API_VERSION}")

    FAILED_JOBS=$(echo "$TIMELINE" | jq -r '.records[] | select(.type=="Job" and .result=="failed") | .name' | sort | uniq)

    if [[ -z "$FAILED_JOBS" ]]; then
        echo -e "${GREEN}No failed jobs found${NC}"
        exit 0
    fi

    echo -e "${BLUE}Failed jobs:${NC}"
    echo "$FAILED_JOBS" | sed 's/^/  /'
else
    # Get artifacts list
    echo -e "${BLUE}Fetching artifacts list...${NC}"
    ARTIFACTS=$(curl -s "${BASE_URL}/${ORGANIZATION}/${PROJECT}/_apis/build/builds/${BUILD_ID}/artifacts?api-version=${API_VERSION}")

    ARTIFACT_COUNT=$(echo "$ARTIFACTS" | jq '.value | length')

    if [[ "$ARTIFACT_COUNT" -eq 0 ]]; then
        echo -e "${RED}No artifacts found for build ${BUILD_ID}${NC}"
        exit 1
    fi

    echo -e "${GREEN}Found ${ARTIFACT_COUNT} artifact(s)${NC}"
fi

# Check if output directory already exists
if [[ -d "$ARTIFACT_DIR" ]]; then
    echo -e "${RED}Error: Directory $ARTIFACT_DIR already exists and will not be overwritten${NC}"
    exit 1
fi

# Create output directory
mkdir -p "$ARTIFACT_DIR"
echo -e "${BLUE}Output directory: ${ARTIFACT_DIR}${NC}"

if [[ "$FAILED_ONLY" == true ]]; then
    # Get all failed jobs and store their names
    echo -e "${BLUE}Downloading logs, artifacts for failed jobs...${NC}"

    # Get all failed jobs
    FAILED_JOBS=$(echo "$TIMELINE" | jq -c '.records[] | select(.type=="Job" and .result=="failed")')
    FAILED_JOB_NAMES=$(echo "$TIMELINE" | jq -r '.records[] | select(.type=="Job" and .result=="failed") | .name' | sort | uniq)

    # Fetch all artifacts from the build
    echo -e "${BLUE}Fetching artifacts list...${NC}"
    ARTIFACTS=$(curl -s "${BASE_URL}/${ORGANIZATION}/${PROJECT}/_apis/build/builds/${BUILD_ID}/artifacts?api-version=${API_VERSION}")

    echo "$FAILED_JOBS" | while read -r job; do
        JOB_ID=$(echo "$job" | jq -r '.id')
        JOB_NAME=$(echo "$job" | jq -r '.name')
        JOB_LOG_URL=$(echo "$job" | jq -r '.log.url')

        echo -e "${BLUE}Processing failed job: ${JOB_NAME}${NC}"

        # Download job-level log
        if [[ -n "$JOB_LOG_URL" && "$JOB_LOG_URL" != "null" ]]; then
            SAFE_JOB_NAME=$(echo "$JOB_NAME" | sed 's/[^a-zA-Z0-9._-]/_/g')
            JOB_LOG_FILE="${ARTIFACT_DIR}/${SAFE_JOB_NAME}_job.log"
            echo -e "${BLUE}  ↓ Downloading job log: ${JOB_NAME}${NC}"

            if curl -s -L -o "$JOB_LOG_FILE" "$JOB_LOG_URL"; then
                FILE_SIZE=$(du -h "$JOB_LOG_FILE" | cut -f1)
                echo -e "${GREEN}    ✓ Downloaded (${FILE_SIZE})${NC}"
            else
                echo -e "${RED}    ✗ Failed to download${NC}"
                rm -f "$JOB_LOG_FILE"
            fi
        fi

        # Download all task logs from this job
        TASKS=$(echo "$TIMELINE" | jq -c ".records[] | select(.parentId==\"$JOB_ID\" and .type==\"Task\")")

        echo "$TASKS" | while read -r task; do
            TASK_NAME=$(echo "$task" | jq -r '.name')
            TASK_LOG_URL=$(echo "$task" | jq -r '.log.url')

            if [[ -z "$TASK_LOG_URL" || "$TASK_LOG_URL" == "null" ]]; then
                continue
            fi

            # Sanitize task name for filename
            SAFE_TASK_NAME=$(echo "${JOB_NAME} - ${TASK_NAME}" | sed 's/[^a-zA-Z0-9._-]/_/g')
            TASK_LOG_FILE="${ARTIFACT_DIR}/${SAFE_TASK_NAME}.log"
            echo -e "${BLUE}  ↓ Downloading task log: ${TASK_NAME}${NC}"

            if curl -s -L -o "$TASK_LOG_FILE" "$TASK_LOG_URL"; then
                FILE_SIZE=$(du -h "$TASK_LOG_FILE" | cut -f1)
                echo -e "${GREEN}    ✓ Downloaded (${FILE_SIZE})${NC}"
            else
                echo -e "${RED}    ✗ Failed to download${NC}"
                rm -f "$TASK_LOG_FILE"
            fi
        done
    done

    # Download artifacts from failed jobs
    echo -e "${BLUE}Downloading artifacts from failed jobs...${NC}"
    echo "$ARTIFACTS" | jq -c '.value[]' | while read -r artifact; do
        ARTIFACT_NAME=$(echo "$artifact" | jq -r '.name')
        DOWNLOAD_URL=$(echo "$artifact" | jq -r '.resource.downloadUrl')

        # Check if this artifact belongs to a failed job
        # Convert job name to artifact format (spaces to dots)
        BELONGS_TO_FAILED=false
        while IFS= read -r failed_job_name; do
            # Convert failed job name to match artifact naming (spaces to dots for logs prefix)
            ARTIFACT_PATTERN=$(echo "$failed_job_name" | sed 's/ /\./g')
            if [[ "$ARTIFACT_NAME" == *"$ARTIFACT_PATTERN"* ]]; then
                BELONGS_TO_FAILED=true
                break
            fi
        done <<< "$FAILED_JOB_NAMES"

        if [[ "$BELONGS_TO_FAILED" == false ]]; then
            continue
        fi

        if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
            echo -e "${RED}  ⚠ ${ARTIFACT_NAME}: No download URL found${NC}"
            continue
        fi

        # For logs artifacts, extract to subdirectory to avoid name clashes
        if [[ "$ARTIFACT_NAME" == logs-* ]]; then
            EXTRACT_DIR="${ARTIFACT_DIR}/${ARTIFACT_NAME}"
            mkdir -p "$EXTRACT_DIR"
            ARTIFACT_FILE="${EXTRACT_DIR}/${ARTIFACT_NAME}.zip"
        else
            ARTIFACT_FILE="${ARTIFACT_DIR}/${ARTIFACT_NAME}"
        fi

        echo -e "${BLUE}  ↓ Downloading artifact: ${ARTIFACT_NAME}${NC}"

        if curl -s -L -o "$ARTIFACT_FILE" "$DOWNLOAD_URL"; then
            FILE_SIZE=$(du -h "$ARTIFACT_FILE" | cut -f1)
            echo -e "${GREEN}    ✓ Downloaded (${FILE_SIZE})${NC}"

            # Extract the artifact
            if [[ "$ARTIFACT_FILE" == *.zip ]]; then
                EXTRACT_TARGET=$(dirname "$ARTIFACT_FILE")
                echo -e "${BLUE}    Extracting zip file...${NC}"
                if unzip -q -o "$ARTIFACT_FILE" -d "$EXTRACT_TARGET"; then
                    echo -e "${GREEN}    ✓ Extracted${NC}"
                    rm -f "$ARTIFACT_FILE"
                else
                    echo -e "${RED}    ✗ Failed to extract${NC}"
                fi
            elif [[ "$ARTIFACT_FILE" == *.tar.gz ]] || [[ "$ARTIFACT_FILE" == *.tgz ]]; then
                EXTRACT_TARGET=$(dirname "$ARTIFACT_FILE")
                echo -e "${BLUE}    Extracting tar.gz file...${NC}"
                if tar -xzf "$ARTIFACT_FILE" -C "$EXTRACT_TARGET"; then
                    echo -e "${GREEN}    ✓ Extracted${NC}"
                    rm -f "$ARTIFACT_FILE"
                else
                    echo -e "${RED}    ✗ Failed to extract${NC}"
                fi
            elif [[ "$ARTIFACT_FILE" == *.tar ]]; then
                EXTRACT_TARGET=$(dirname "$ARTIFACT_FILE")
                echo -e "${BLUE}    Extracting tar file...${NC}"
                if tar -xf "$ARTIFACT_FILE" -C "$EXTRACT_TARGET"; then
                    echo -e "${GREEN}    ✓ Extracted${NC}"
                    rm -f "$ARTIFACT_FILE"
                else
                    echo -e "${RED}    ✗ Failed to extract${NC}"
                fi
            fi
        else
            echo -e "${RED}    ✗ Failed to download${NC}"
            rm -f "$ARTIFACT_FILE"
        fi
    done
else
    # Download all artifacts
    echo "$ARTIFACTS" | jq -c '.value[]' | while read -r artifact; do
        ARTIFACT_NAME=$(echo "$artifact" | jq -r '.name')
        DOWNLOAD_URL=$(echo "$artifact" | jq -r '.resource.downloadUrl')

        if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
            echo -e "${RED}  ⚠ ${ARTIFACT_NAME}: No download URL found${NC}"
            continue
        fi

        ARTIFACT_FILE="${ARTIFACT_DIR}/${ARTIFACT_NAME}"
        echo -e "${BLUE}  ↓ Downloading: ${ARTIFACT_NAME}${NC}"

        if curl -s -L -o "$ARTIFACT_FILE" "$DOWNLOAD_URL"; then
            FILE_SIZE=$(du -h "$ARTIFACT_FILE" | cut -f1)
            echo -e "${GREEN}    ✓ Downloaded (${FILE_SIZE})${NC}"
        else
            echo -e "${RED}    ✗ Failed to download${NC}"
            rm -f "$ARTIFACT_FILE"
        fi
    done
fi

echo -e "${GREEN}Done! Files saved to: ${ARTIFACT_DIR}${NC}"
