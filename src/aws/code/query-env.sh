#!/bin/bash

# Query environment variables stored in AWS SSM Parameter Store
# for a specific environment (production, staging, development)

set -e

# Get the directory where this script is ACTUALLY located (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

# Source libraries
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/lib"
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/codedeploy"

# Load CodeDeploy configuration from project directory
if ! load_cd_config; then
    prompt_error "CodeDeploy configuration not found"
    echo ""
    echo "This script looks for .codedeploy/config in the current directory or parent directories."
    echo "Run aws-code-setup.sh from your project directory first to create the configuration."
    exit 1
fi

# Configuration is now loaded via load_cd_config, which sets:
# - CD_PROJECT_ROOT
# - PROJECT_NAME
# - AWS_REGION
# - Other CD_* variables

# Validate required variables
if [ -z "$PROJECT_NAME" ]; then
    prompt_error "PROJECT_NAME not set in configuration"
    exit 1
fi

if [ -z "$AWS_REGION" ]; then
    prompt_error "AWS_REGION not set in configuration"
    exit 1
fi

# Display header
prompt_header "Query Environment Variables" "$PROJECT_NAME"
echo ""

# Select environment
environment_options=("production" "staging" "development")
if ! prompt_select ENVIRONMENT "Select environment" 0 "${environment_options[@]}"; then
    prompt_error "Failed to read input. Exiting."
    exit 1
fi

echo ""
prompt_info "Querying environment variables for: $ENVIRONMENT"
echo ""

# Function to query and display parameters
query_parameters() {
    local path_prefix=$1
    local param_type=$2

    # Query SSM parameters
    local params=$(aws ssm get-parameters-by-path \
        --path "$path_prefix" \
        --with-decryption \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo '{"Parameters":[]}')

    local param_count=$(echo "$params" | jq -r '.Parameters | length')

    if [ "$param_count" -eq 0 ]; then
        echo -e "${CD_DIM}  No ${param_type} variables found${CD_RESET}"
        return
    fi

    # Parse and display parameters
    echo "$params" | jq -r '.Parameters[] | "\(.Name)=\(.Value)"' | while IFS= read -r param; do
        # Extract just the key name (last part after /)
        local full_name=$(echo "$param" | cut -d'=' -f1)
        local key=$(basename "$full_name")
        local value=$(echo "$param" | cut -d'=' -f2-)

        # Display with color
        echo -e "  ${CD_YELLOW}${key}${CD_RESET}=${CD_GREEN}${value}${CD_RESET}"
    done
}

# Query build variables
echo -e "${CD_BOLD}Build Variables${CD_RESET} ${CD_DIM}(used during CI/CD build phase)${CD_RESET}"
query_parameters "/${PROJECT_NAME}/${ENVIRONMENT}/build" "build"
echo ""

# Query runtime variables
echo -e "${CD_BOLD}Runtime Variables${CD_RESET} ${CD_DIM}(deployed to application)${CD_RESET}"
query_parameters "/${PROJECT_NAME}/${ENVIRONMENT}" "runtime"

echo ""
prompt_success "Query complete"
