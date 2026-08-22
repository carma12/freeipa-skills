#!/bin/bash

set -euo pipefail

# Configuration
ORGANIZATION="freeipa"
PROJECT="freeipa"
DEFINITION_ID="3"
BASE_URL="https://dev.azure.com"
API_VERSION="7.0"
GITHUB_API_URL="https://api.github.com/repos/freeipa/freeipa"

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

# Check if output directory already exists
if [[ -d "$ARTIFACT_DIR" ]]; then
    echo -e "${RED}Error: Directory $ARTIFACT_DIR already exists and will not be overwritten${NC}"
    exit 1
fi

ANYTHING_FOUND=false

# ============================
# Azure DevOps Section
# ============================
echo -e "${BLUE}Searching for Azure DevOps builds associated with PR #${PR_NUMBER}...${NC}"

# Search for the most recent build for this PR
# Azure uses pull/{PR}/merge format for PR branches
BUILD_LIST=$(curl -s "${BASE_URL}/${ORGANIZATION}/${PROJECT}/_apis/build/builds?definitions=${DEFINITION_ID}&statusFilter=completed&api-version=${API_VERSION}")

# Parse the JSON to find builds with matching PR, sorted by finish time (most recent first)
BUILD_ID=$(echo "$BUILD_LIST" | jq -r ".value[] | select(.sourceBranch | contains(\"pull/${PR_NUMBER}\")) | {id: .id, finishTime: .finishTime}" | jq -s 'sort_by(.finishTime) | reverse | .[0].id')

if [[ -z "$BUILD_ID" || "$BUILD_ID" == "null" ]]; then
    echo -e "${RED}Warning: No Azure DevOps builds found for PR #${PR_NUMBER}${NC}"
else
    ANYTHING_FOUND=true
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
            echo -e "${GREEN}No failed Azure DevOps jobs found${NC}"
        else
            echo -e "${BLUE}Failed jobs:${NC}"
            echo "$FAILED_JOBS" | sed 's/^/  /'

            # Create output directory
            mkdir -p "$ARTIFACT_DIR"
            echo -e "${BLUE}Output directory: ${ARTIFACT_DIR}${NC}"

            # Download logs and artifacts for failed jobs
            echo -e "${BLUE}Downloading logs, artifacts for failed jobs...${NC}"

            FAILED_JOBS_JSON=$(echo "$TIMELINE" | jq -c '.records[] | select(.type=="Job" and .result=="failed")')
            FAILED_JOB_NAMES=$(echo "$TIMELINE" | jq -r '.records[] | select(.type=="Job" and .result=="failed") | .name' | sort | uniq)

            # Fetch all artifacts from the build
            echo -e "${BLUE}Fetching artifacts list...${NC}"
            ARTIFACTS=$(curl -s "${BASE_URL}/${ORGANIZATION}/${PROJECT}/_apis/build/builds/${BUILD_ID}/artifacts?api-version=${API_VERSION}")

            echo "$FAILED_JOBS_JSON" | while read -r job; do
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
                BELONGS_TO_FAILED=false
                while IFS= read -r failed_job_name; do
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
        fi
    else
        # Get artifacts list
        echo -e "${BLUE}Fetching artifacts list...${NC}"
        ARTIFACTS=$(curl -s "${BASE_URL}/${ORGANIZATION}/${PROJECT}/_apis/build/builds/${BUILD_ID}/artifacts?api-version=${API_VERSION}")

        ARTIFACT_COUNT=$(echo "$ARTIFACTS" | jq '.value | length')

        if [[ "$ARTIFACT_COUNT" -eq 0 ]]; then
            echo -e "${RED}No artifacts found for build ${BUILD_ID}${NC}"
        else
            echo -e "${GREEN}Found ${ARTIFACT_COUNT} artifact(s)${NC}"

            # Create output directory
            mkdir -p "$ARTIFACT_DIR"
            echo -e "${BLUE}Output directory: ${ARTIFACT_DIR}${NC}"

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
    fi
fi

# ============================
# PR-CI Section
# ============================
echo -e "${BLUE}Searching for PR-CI jobs associated with PR #${PR_NUMBER}...${NC}"

HEAD_SHA=$(curl -s "${GITHUB_API_URL}/pulls/${PR_NUMBER}" | jq -r '.head.sha')

if [[ -z "$HEAD_SHA" || "$HEAD_SHA" == "null" ]]; then
    echo -e "${RED}Warning: Could not get PR head SHA for PR-CI lookup${NC}"
else
    STATUSES=$(curl -s "${GITHUB_API_URL}/commits/${HEAD_SHA}/statuses?per_page=100")

    # Get unique PR-CI statuses (API returns newest first, unique_by keeps the first)
    if [[ "$FAILED_ONLY" == true ]]; then
        PRCI_JOBS=$(echo "$STATUSES" | jq -c '
            [.[] | select(.target_url != null and .target_url != "" and (.target_url | test("freeipa-org-pr-ci")))]
            | unique_by(.context)
            | map(select(.state == "error" or .state == "failure"))
        ')
    else
        PRCI_JOBS=$(echo "$STATUSES" | jq -c '
            [.[] | select(.target_url != null and .target_url != "" and (.target_url | test("freeipa-org-pr-ci")))]
            | unique_by(.context)
        ')
    fi

    PRCI_COUNT=$(echo "$PRCI_JOBS" | jq 'length')

    if [[ "$PRCI_COUNT" -gt 0 ]]; then
        ANYTHING_FOUND=true
        echo -e "${GREEN}Found ${PRCI_COUNT} PR-CI job(s)${NC}"

        mkdir -p "$ARTIFACT_DIR"

        echo "$PRCI_JOBS" | jq -c '.[]' | while read -r job; do
            CONTEXT=$(echo "$job" | jq -r '.context')
            STATE=$(echo "$job" | jq -r '.state')
            TARGET_URL=$(echo "$job" | jq -r '.target_url')
            DESCRIPTION=$(echo "$job" | jq -r '.description')

            echo -e "${BLUE}Processing PR-CI job: ${CONTEXT} (${STATE})${NC}"
            echo "  Description: ${DESCRIPTION}"
            echo "  URL: ${TARGET_URL}"

            SAFE_CONTEXT=$(echo "$CONTEXT" | sed 's/[^a-zA-Z0-9._-]/_/g')
            PRCI_DIR="${ARTIFACT_DIR}/prci-${SAFE_CONTEXT}"
            mkdir -p "$PRCI_DIR"

            # Save job URL for reference
            echo "$TARGET_URL" > "${PRCI_DIR}/job-url.txt"

            # Download runner.log.gz (main test log)
            echo -e "${BLUE}  ↓ Downloading runner.log${NC}"
            if curl -s -f -L -o "${PRCI_DIR}/runner.log.gz" "${TARGET_URL}/runner.log.gz"; then
                if gunzip "${PRCI_DIR}/runner.log.gz" 2>/dev/null; then
                    FILE_SIZE=$(du -h "${PRCI_DIR}/runner.log" | cut -f1)
                    echo -e "${GREEN}    ✓ Downloaded and decompressed (${FILE_SIZE})${NC}"
                else
                    FILE_SIZE=$(du -h "${PRCI_DIR}/runner.log.gz" | cut -f1)
                    echo -e "${GREEN}    ✓ Downloaded (${FILE_SIZE}, could not decompress)${NC}"
                fi
            else
                echo -e "${RED}    ✗ Failed to download (may not exist for this job type)${NC}"
                rm -f "${PRCI_DIR}/runner.log.gz"
            fi

            # Download metadata.json
            echo -e "${BLUE}  ↓ Downloading metadata.json${NC}"
            if curl -s -f -L -o "${PRCI_DIR}/metadata.json" "${TARGET_URL}/metadata.json"; then
                FILE_SIZE=$(du -h "${PRCI_DIR}/metadata.json" | cut -f1)
                echo -e "${GREEN}    ✓ Downloaded (${FILE_SIZE})${NC}"
            else
                echo -e "${RED}    ✗ Failed to download${NC}"
                rm -f "${PRCI_DIR}/metadata.json"
            fi

            # Download ipa-test-config.yaml
            echo -e "${BLUE}  ↓ Downloading ipa-test-config.yaml${NC}"
            if curl -s -f -L -o "${PRCI_DIR}/ipa-test-config.yaml" "${TARGET_URL}/ipa-test-config.yaml"; then
                FILE_SIZE=$(du -h "${PRCI_DIR}/ipa-test-config.yaml" | cut -f1)
                echo -e "${GREEN}    ✓ Downloaded (${FILE_SIZE})${NC}"
            else
                echo -e "${RED}    ✗ Failed to download${NC}"
                rm -f "${PRCI_DIR}/ipa-test-config.yaml"
            fi

            # Download vars.yml (job configuration)
            echo -e "${BLUE}  ↓ Downloading vars.yml${NC}"
            if curl -s -f -L -o "${PRCI_DIR}/vars.yml" "${TARGET_URL}/vars.yml"; then
                FILE_SIZE=$(du -h "${PRCI_DIR}/vars.yml" | cut -f1)
                echo -e "${GREEN}    ✓ Downloaded (${FILE_SIZE})${NC}"
            else
                echo -e "${RED}    ✗ Failed to download${NC}"
                rm -f "${PRCI_DIR}/vars.yml"
            fi
        done
    else
        if [[ "$FAILED_ONLY" == true ]]; then
            echo -e "${BLUE}No failed PR-CI jobs found${NC}"
        else
            echo -e "${BLUE}No PR-CI jobs found${NC}"
        fi
    fi
fi

if [[ "$ANYTHING_FOUND" == false ]]; then
    echo -e "${RED}Error: No CI results found for PR #${PR_NUMBER}${NC}"
    exit 1
fi

echo -e "${GREEN}Done! Files saved to: ${ARTIFACT_DIR}${NC}"
