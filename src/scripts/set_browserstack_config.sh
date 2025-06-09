#!/bin/bash

# Check if CircleCI token is set
if [[ -z "$CIRCLECI_TOKEN" ]]; then
  echo "CircleCI token (CIRCLECI_TOKEN) is not set. Exiting."
  exit 1
fi

# Fetch workflow name using CircleCI API
echo "Fetching workflow details..."
WORKFLOW_RESPONSE=$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" \
  "https://circleci.com/api/v2/workflow/${CIRCLE_WORKFLOW_ID}")

if [[ -z "$WORKFLOW_RESPONSE" ]]; then
  echo "Failed to fetch workflow details. Exiting."
  exit 0
fi

WORKFLOW_NAME=$(echo "$WORKFLOW_RESPONSE" | jq -r '.name // empty')

if [[ -z "$WORKFLOW_NAME" ]]; then
  echo "Workflow name not found in response. Exiting."
  exit 0
fi

echo "Workflow name: $WORKFLOW_NAME"

# Set BrowserStack build name
export BROWSERSTACK_BUILD_NAME="circleci-${WORKFLOW_NAME}-${CIRCLE_BUILD_NUM}"
echo "BrowserStack build name set to: $BROWSERSTACK_BUILD_NAME"

# Set BrowserStack credentials
if [[ -z "$BROWSERSTACK_USERNAME" || -z "$BROWSERSTACK_ACCESS_KEY" ]]; then
  echo "BrowserStack credentials are not set. Please add it into your environment variable. Exiting."
  exit 1
fi

# Export build name to job scope environment
echo "export BROWSERSTACK_BUILD_NAME=\"${BROWSERSTACK_BUILD_NAME}\"" >> "$BASH_ENV"

echo "BrowserStack credentials and build name exported to job scope environment."
