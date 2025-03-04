#!/bin/bash

# Logger function
logger() {
  local level="$1"
  local message="$2"

  case "$level" in
    "INFO")    echo -e "\033[1;34m[INFO]\033[0m $message" ;;   # Blue
    "SUCCESS") echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;; # Green
    "ERROR")   echo -e "\033[1;31m[ERROR]\033[0m $message" ;;   # Red
    "WARNING") echo -e "\033[1;33m[WARNING]\033[0m $message" ;; # Yellow
    *)         echo "[LOG] $message" ;;                         # Default
  esac
}

cleanup_env_var() {
  logger "INFO" "Delete env var : $DELETE_ENV_VAR"
  logger "INFO" "Cleanup env var : $CLEANUP_ENV_VAR"
  if [[ "$DELETE_ENV_VAR" == "1" || "$CLEANUP_ENV_VAR" == "1" ]]; then
    logger "INFO" "Deleting the project environment variable: $env_var"
    curl -X DELETE "https://circleci.com/api/v2/project/${PROJECT_SLUG}/envvar/${env_var}" \
        -H "Circle-Token: ${CIRCLECI_TOKEN}" \
        -H "Content-Type: application/json"
    logger "SUCCESS" "Deleted environment variable: $env_var"
  fi
}

set_env_var() {
  if [[ -z "$CLEANUP_ENV_VAR" || "$CLEANUP_ENV_VAR" != "true" ]]; then
    logger "INFO" "Setting BS_env_vars in BASH_ENV"
    decoded_json=$(echo "$env_var_value" | base64 --decode 2>/dev/null)

    if echo "$decoded_json" | jq empty 2>/dev/null; then
        logger "SUCCESS" "Valid JSON detected."
        echo "$decoded_json" | jq .
        echo "$decoded_json" | jq -r 'to_entries | .[] | "export " + .key + "=\"" + (.value | tostring) + "\""' >> "$BASH_ENV"
    else
        logger "ERROR" "Invalid JSON detected. Exiting."
        exit 0
    fi
  fi
}

sanitizeToAlphanumericKey() {
  local key="$1"
  echo "${key//[^a-zA-Z0-9]/_}"
}

sanitizeAndLimit() {
  local key="$1"
  local sanitized_key
  sanitized_key=$(sanitizeToAlphanumericKey "$key")
  echo "${sanitized_key:0:50}"
}

buildEnvironmentVariable() {
  local envKey="$1"
  shift
  local values=("$@")

  sanitized_values=()
  for value in "${values[@]}"; do
    sanitized_values+=("$(sanitizeAndLimit "$value")")
  done

  echo "$envKey"_"$(IFS=_; echo "${sanitized_values[*]}")"
}

# Check whether CircleCI token is present
if [[ -z "$CIRCLECI_TOKEN" ]]; then
  logger "ERROR" "CircleCI token not present in environment variables. Setting no tests to rerun."
  exit 0
fi

logger "INFO" "Fetching workflow details..."
WORKFLOW_RESPONSE=$(curl -s -H "Circle-Token: ${CIRCLECI_TOKEN}" \
                        "https://circleci.com/api/v2/workflow/${CIRCLE_WORKFLOW_ID}")

if echo "$WORKFLOW_RESPONSE" | jq empty 2>/dev/null; then
  WORKFLOW_NAME=$(echo "$WORKFLOW_RESPONSE" | jq -r '.name // empty')
  PROJECT_SLUG=$(echo "$WORKFLOW_RESPONSE" | jq -r '.project_slug // empty')
  WORKFLOW_TAG=$(echo "$WORKFLOW_RESPONSE" | jq -r '.tag // empty')

  if [[ -z "$WORKFLOW_NAME" || -z "$PROJECT_SLUG" ]]; then
    logger "ERROR" "Missing workflow name or project slug in API response. Setting no tests to rerun."
    exit 0
  fi

  if [[ "$WORKFLOW_TAG" == "rerun-workflow-from-beginning" ]]; then
    logger "SUCCESS" "Workflow is a rerun from the beginning. Proceeding with env var operations..."
  else
    logger "WARNING" "Workflow is not a rerun from the beginning (tag: $WORKFLOW_TAG). Setting no tests to rerun."
    exit 0
  fi
else
  logger "ERROR" "Invalid response from CircleCI API. Check your API token. Setting no tests to rerun."
  exit 0
fi

# Build environment variable
ENV_KEY="BS_RERUN"
env_var=$(buildEnvironmentVariable "$ENV_KEY" "$CIRCLE_PIPELINE_ID" "$WORKFLOW_NAME" "$CIRCLE_USERNAME")

logger "INFO" "Looking for environment variable: $env_var"
env_var_value=$(printenv "$env_var") || env_var_value=""

if [[ -n "$env_var_value" ]]; then
  set_env_var
  cleanup_env_var
else
  logger "WARNING" "No value found for environment variable: $env_var"
fi
