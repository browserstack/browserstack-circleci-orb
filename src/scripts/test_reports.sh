#!/bin/bash

# Constants
API_PATH="https://api-observability.browserstack.com/ext/v1/builds/buildReport"
REPORT_STATUS_COMPLETED="COMPLETED"
REPORT_STATUS_NOT_AVAILABLE="NOT_AVAILABLE"
REPORT_STATUS_TEST_AVAILABLE="TEST_AVAILABLE"
REPORT_STATUS_IN_PROGRESS="IN_PROGRESS"
REQUESTING_CI="circle-ci"
REPORT_FORMAT='["plainText", "richHtml"]'

# Error scenario mappings
declare -A ERROR_SCENARIOS=(
  ["BUILD_NOT_FOUND"]="Build not found in BrowserStack"
  ["MULTIPLE_BUILD_FOUND"]="Multiple builds found with the same name"
  ["DATA_NOT_AVAILABLE"]="Report data not available from BrowserStack"
)
  
# Check if BROWSERSTACK_BUILD_NAME is set
if [[ -z "$BROWSERSTACK_BUILD_NAME" ]]; then
  echo "Error: BROWSERSTACK_BUILD_NAME is not set."
  exit 0
fi

if [[ "$USER_TIMEOUT" -lt 20 || "$USER_TIMEOUT" -gt 600 ]]; then
  echo "Error: USER_TIMEOUT must be between 20 and 600 seconds."
  exit 1
fi

# Function to make API requests
make_api_request() {
  local request_type=$1
  local auth_header
  local header_file
  local response

  # Encode username:accesskey to base64
  auth_header=$(echo -n "${BROWSERSTACK_USERNAME}:${BROWSERSTACK_ACCESS_KEY}" | base64)
  # Create a temporary file for headers
  header_file=$(mktemp)
  response=$(curl -s -w "%{http_code}" -X POST "$API_PATH" \
    -H "Content-Type: application/json" \
    -H "Authorization: Basic $auth_header" \
    -D "$header_file" \
    -d "{
          \"originalBuildName\": \"${BROWSERSTACK_BUILD_NAME}\",
          \"buildStartedAt\": \"$(date +%s)\",
          \"requestingCi\": \"$REQUESTING_CI\",
          \"reportFormat\": $REPORT_FORMAT,
          \"requestType\": \"$request_type\",
          \"userTimeout\": \"${USER_TIMEOUT}\"
        }")
  
  # Extract the HTTP status code from the response
  local http_status=${response: -3}
  # Extract the response body (everything except the last 3 characters)
  local body=${response:0:${#response}-3}
  
  # Clean up the temporary file
  rm -f "$header_file"
  
  if [[ -z "$body" ]]; then
    body='""'
  fi

  # Return both status code and body as a JSON object
  echo "{\"status_code\": $http_status, \"body\": $body}"
}

# Function to extract report data
extract_report_data() {
    local response=$1
    rich_html_response=$(echo "$response" | jq -r '.report.richHtml // empty')
    rich_css_response=$(echo "$response" | jq -r '.report.richCss // empty')
    plain_text_response=$(echo "$response" | jq -r '.report.plainText // empty')
}

# Function to check report status
check_report_status() {
    local response=$1
    local status_code
    local body
    local error_message
    
    status_code=$(echo "$response" | jq -r '.status_code')
    body=$(echo "$response" | jq -r '.body')
    
    if [[ $status_code -ne 200 ]]; then
        echo "Error: API returned status code $status_code"
        error_message=$(echo "$body" | jq -r '.message // "Unknown error"')
        echo "Error message: $error_message"
        return 1
    fi
    
    REPORT_STATUS=$(echo "$body" | jq -r '.reportStatus // empty')
    if [[ "$REPORT_STATUS" == "$REPORT_STATUS_COMPLETED" || 
        "$REPORT_STATUS" == "$REPORT_STATUS_TEST_AVAILABLE" ||
        "$REPORT_STATUS" == "$REPORT_STATUS_NOT_AVAILABLE" ]]; then
        extract_report_data "$body"
        return 0
    fi
    return 2
}
echo "Making initial API request to Browserstack Test Report API..."

# Initial API Request
RESPONSE=$(make_api_request "FIRST")
check_report_status "$RESPONSE" || true
RETRY_COUNT=$(echo "$RESPONSE" | jq -r '.body.retryCount // 3')
POLLING_DURATION=$(echo "$RESPONSE" | jq -r '.body.pollingInterval // 3000')
POLLING_DURATION=$((POLLING_DURATION / 1000))

# Polling Mechanism
[ "$REPORT_STATUS" == "$REPORT_STATUS_IN_PROGRESS" ]  && {
  echo "Starting polling mechanism to fetch Test report..."
}
local_retry=0
ELAPSED_TIME=0

while [[ $local_retry -lt $RETRY_COUNT && $REPORT_STATUS == "$REPORT_STATUS_IN_PROGRESS" ]]; do
    if [[ -n "$USER_TIMEOUT" && "$ELAPSED_TIME" -ge "$USER_TIMEOUT" ]]; then
        echo "User timeout reached. Making final API request..."
        RESPONSE=$(make_api_request "LAST")
        check_report_status "$RESPONSE" && break
        break
    fi

    ELAPSED_TIME=$((ELAPSED_TIME + POLLING_DURATION))
    local_retry=$((local_retry + 1))

    RESPONSE=$(make_api_request "POLL")
    echo "Polling attempt $local_retry/$RETRY_COUNT"
    
    # Stop polling if API response is non-200
    status_code=$(echo "$RESPONSE" | jq -r '.status_code')
    if [[ $status_code -ne 200 ]]; then
        echo "Polling stopped due to non-200 response from API. Status code: $status_code"
        break
    fi

    check_report_status "$RESPONSE" && {
        echo "Valid report status received. Exiting polling loop...."
        break
    }
    
    sleep "$POLLING_DURATION"
done

# Handle Report
if [[ -n "$rich_html_response" ]]; then
  # Embed CSS into the rich HTML report
  mkdir -p browserstack
  echo "<!DOCTYPE html>
<html>
<head>
<style>
$rich_css_response
</style>
</head>
$rich_html_response
</html>" > browserstack/testreport.html
  echo "Rich html report saved as browserstack/testreport.html. To view the report, open artifacts tab & click on testreport.html"

  # Generate plain text report
  if [[ -n "$plain_text_response" ]]; then
    echo ""
    echo "Browserstack textual report"
    echo "$plain_text_response"
  else
    echo "Plain text response is empty."
  fi
elif [[ "$REPORT_STATUS" == "$REPORT_STATUS_NOT_AVAILABLE" ]]; then
  error_reason=$(echo "$RESPONSE" | jq -r '.body.errorReason // empty')
  default_error_message="Failed to retrieve report. Reason:"
  if [[ -n "$error_reason" ]]; then
    echo "$default_error_message ${ERROR_SCENARIOS[$error_reason]:-$error_reason}"
  else
    echo "$default_error_message Unexpected error"
  fi
else
  echo "Failed to retrieve report."
fi
# Ensure pipeline doesn't exit with non-zero status
exit 0
