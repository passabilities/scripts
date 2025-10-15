#!/bin/bash

# AWS CodeDeploy Info & Status Display
# Shows configuration, deployment history, and current status

set -e

# Get the directory where this script is ACTUALLY located (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

# Calculate LIB_DIR based on actual script location
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/lib"

# Source libraries
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/config-display"
source "${LIB_DIR}/config-prompt"
source "${LIB_DIR}/codedeploy"

# Try to load project-specific CodeDeploy config
CONFIG_LOADED=false
PROJECT_ROOT=""
SKIP_PROMPTS=false

if load_cd_config; then
    CONFIG_LOADED=true
    PROJECT_ROOT="$CD_PROJECT_ROOT"
    SKIP_PROMPTS=true

    # Config loaded successfully - use it without prompting
    # The config file exports: PROJECT_NAME, ENVIRONMENT, AWS_REGION, etc.
    # Set FILTER_BY_PROJECT to true when using project config
    export FILTER_BY_PROJECT="true"

    # Debug: Show that config was loaded
    echo -e "${CD_DIM}Loaded CodeDeploy config from: ${PROJECT_ROOT}/${CD_CONFIG_DIR}/${CD_CONFIG_FILE}${CD_RESET}" >&2

    # Verify required variables are set
    if [ -z "$AWS_REGION" ] || [ -z "$PROJECT_NAME" ] || [ -z "$ENVIRONMENT" ]; then
        prompt_error "Loaded config is missing required variables (AWS_REGION, PROJECT_NAME, or ENVIRONMENT)"
        SKIP_PROMPTS=false
    fi
fi

# Only prompt if we didn't successfully load a project config
if [ "$SKIP_PROMPTS" = false ]; then
    # No project config found - prompt for AWS configuration
    # This allows showing all resources or specific project
    if ! load_existing_config; then
        # No AWS config either
        prompt_info "No CodeDeploy or AWS configuration found"
        echo ""
    fi

    # Prompt for configuration (allows "show all" option)
    prompt_aws_config "true" "visualization"
fi

# Display function for application details
display_application_info() {
    local app_name=$1
    local region=${2:-$AWS_REGION}

    print_box_header "CodeDeploy Application"

    # Get application details
    local app_info=$(aws deploy get-application \
        --application-name "$app_name" \
        --region "$region" \
        --output json 2>/dev/null)

    if [ -z "$app_info" ] || [ "$app_info" = "null" ]; then
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_RED}Application not found: $app_name${CD_RESET}"
        print_box_footer
        return 1
    fi

    local app_id=$(echo "$app_info" | jq -r '.application.applicationId // "N/A"')
    local compute_platform=$(echo "$app_info" | jq -r '.application.computePlatform // "N/A"')
    local create_time=$(echo "$app_info" | jq -r '.application.createTime // "N/A"')

    print_box_line "Application Name" "$app_name"
    print_box_line "Application ID" "$app_id"
    print_box_line "Compute Platform" "$compute_platform"

    if [ "$create_time" != "N/A" ]; then
        local formatted_time=$(format_timestamp "$create_time")
        print_box_line "Created" "$formatted_time"
    fi

    print_box_footer
}

# Display function for deployment group details
display_deployment_group_info() {
    local app_name=$1
    local deployment_group=$2
    local region=${3:-$AWS_REGION}

    echo ""
    print_box_header "Deployment Group"

    # Get deployment group details
    local dg_info=$(aws deploy get-deployment-group \
        --application-name "$app_name" \
        --deployment-group-name "$deployment_group" \
        --region "$region" \
        --output json 2>/dev/null)

    if [ -z "$dg_info" ] || [ "$dg_info" = "null" ]; then
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_RED}Deployment group not found: $deployment_group${CD_RESET}"
        print_box_footer
        return 1
    fi

    local service_role=$(echo "$dg_info" | jq -r '.deploymentGroupInfo.serviceRoleArn // "N/A"')
    local deployment_config=$(echo "$dg_info" | jq -r '.deploymentGroupInfo.deploymentConfigName // "N/A"')
    local auto_rollback=$(echo "$dg_info" | jq -r '.deploymentGroupInfo.autoRollbackConfiguration.enabled // false')

    print_box_line "Deployment Group" "$deployment_group"
    print_box_line "Deployment Config" "$deployment_config"
    print_box_line "Service Role" "...${service_role: -30}"
    print_box_line "Auto Rollback" "$auto_rollback"

    # Target information
    local ec2_tags=$(echo "$dg_info" | jq -r '.deploymentGroupInfo.ec2TagFilters // [] | length')
    local asg_names=$(echo "$dg_info" | jq -r '.deploymentGroupInfo.autoScalingGroups // [] | length')

    if [ "$ec2_tags" -gt 0 ]; then
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}Target EC2 Tags:${CD_RESET}"
        echo "$dg_info" | jq -r '.deploymentGroupInfo.ec2TagFilters[] | "  \(.Key)=\(.Value)"' | while read -r tag; do
            echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}    ${CD_GREEN}$tag${CD_RESET}"
        done
    fi

    if [ "$asg_names" -gt 0 ]; then
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}Auto Scaling Groups:${CD_RESET}"
        echo "$dg_info" | jq -r '.deploymentGroupInfo.autoScalingGroups[].name' | while read -r asg; do
            echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}    ${CD_GREEN}$asg${CD_RESET}"
        done
    fi

    print_box_footer
}

# Display function for recent deployments
display_recent_deployments() {
    local app_name=$1
    local deployment_group=$2
    local region=${3:-$AWS_REGION}
    local limit=${4:-5}

    echo ""
    print_box_header "Recent Deployments"

    # Get deployment IDs
    local deployment_ids=$(list_recent_deployments "$app_name" "$deployment_group" "$region" "$limit")

    if [ -z "$deployment_ids" ]; then
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}No deployments found${CD_RESET}"
        print_box_footer
        return 0
    fi

    # Header
    printf "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}%-10s %-20s %-15s %-25s${CD_RESET}\n" \
        "Status" "Revision" "Created" "Duration"
    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}$(printf '─%.0s' {1..71})${CD_RESET}"

    # Process each deployment
    for deployment_id in $deployment_ids; do
        [ -z "$deployment_id" ] && continue

        local deployment_info=$(get_deployment_info "$deployment_id" "$region")

        local status=$(echo "$deployment_info" | jq -r '.deploymentInfo.status // "Unknown"')
        local revision=$(echo "$deployment_info" | jq -r '.deploymentInfo.revision.s3Location.key // .deploymentInfo.revision.gitHubLocation.repository // "N/A"' | tail -c 20)
        local create_time=$(echo "$deployment_info" | jq -r '.deploymentInfo.createTime // "N/A"')
        local complete_time=$(echo "$deployment_info" | jq -r '.deploymentInfo.completeTime // "N/A"')

        local formatted_create=$(format_timestamp "$create_time" | cut -d' ' -f1,2)

        # Calculate duration if completed
        local duration="Pending"
        if [ "$complete_time" != "N/A" ] && [ "$complete_time" != "null" ]; then
            local create_epoch=$(date -d "$create_time" +%s 2>/dev/null || echo "0")
            local complete_epoch=$(date -d "$complete_time" +%s 2>/dev/null || echo "0")
            if [ "$create_epoch" -gt 0 ] && [ "$complete_epoch" -gt 0 ]; then
                local duration_secs=$((complete_epoch - create_epoch))
                local duration_mins=$((duration_secs / 60))
                duration="${duration_mins}m"
            fi
        fi

        # Format status with color
        local indicator=$(get_health_indicator "$status")

        printf "${CD_BOLD}${CD_CYAN}║${CD_RESET}  %b %-18s ${CD_DIM}%-15s${CD_RESET} ${CD_DIM}%-25s${CD_RESET} ${CD_DIM}%s${CD_RESET}\n" \
            "$indicator" "$status" "...${revision}" "$formatted_create" "$duration"
    done

    print_box_footer
}

# Display function for target instances
display_target_instances() {
    local app_name=$1
    local deployment_group=$2
    local region=${3:-$AWS_REGION}

    echo ""
    print_box_header "Target Instances"

    # Get deployment group details to find targets
    local dg_info=$(aws deploy get-deployment-group \
        --application-name "$app_name" \
        --deployment-group-name "$deployment_group" \
        --region "$region" \
        --output json 2>/dev/null)

    if [ -z "$dg_info" ] || [ "$dg_info" = "null" ]; then
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_RED}Could not retrieve target information${CD_RESET}"
        print_box_footer
        return 1
    fi

    # Get EC2 tag filters
    local tag_filters=$(echo "$dg_info" | jq -r '.deploymentGroupInfo.ec2TagFilters[] | "\(.Key)=\(.Value)"' 2>/dev/null)

    if [ -n "$tag_filters" ]; then
        # Build AWS CLI filters
        local aws_filters=""
        while IFS= read -r tag_filter; do
            local key=$(echo "$tag_filter" | cut -d'=' -f1)
            local value=$(echo "$tag_filter" | cut -d'=' -f2-)
            aws_filters="$aws_filters Name=tag:$key,Values=$value"
        done <<< "$tag_filters"

        # Query EC2 instances
        local instances=$(aws ec2 describe-instances \
            --region "$region" \
            --filters $aws_filters "Name=instance-state-name,Values=running,stopped" \
            --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0],PrivateIpAddress]' \
            --output text 2>/dev/null)

        if [ -n "$instances" ]; then
            printf "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}%-20s %-12s %-25s %-15s${CD_RESET}\n" \
                "Instance ID" "State" "Name" "Private IP"
            echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}$(printf '─%.0s' {1..71})${CD_RESET}"

            while IFS=$'\t' read -r instance_id state name private_ip; do
                [ -z "$instance_id" ] && continue

                local state_indicator=$(get_health_indicator "$state")
                [ -z "$name" ] && name="N/A"
                [ -z "$private_ip" ] && private_ip="N/A"

                printf "${CD_BOLD}${CD_CYAN}║${CD_RESET}  %b %-18s ${CD_GREEN}%-12s${CD_RESET} ${CD_DIM}%-25s${CD_RESET} ${CD_DIM}%s${CD_RESET}\n" \
                    "$state_indicator" "$instance_id" "$state" "$name" "$private_ip"
            done <<< "$instances"
        else
            echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_YELLOW}No instances found matching tag filters${CD_RESET}"
        fi
    else
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}No EC2 tag filters configured${CD_RESET}"
    fi

    print_box_footer
}

# Display project configuration
display_project_config() {
    echo ""
    print_box_header "Project Configuration"

    if [ "$CONFIG_LOADED" = true ]; then
        print_box_line "Config Location" "${PROJECT_ROOT}/${CD_CONFIG_DIR}/${CD_CONFIG_FILE}"
        print_box_line "Project Root" "$PROJECT_ROOT"

        if [ -n "$CD_APPSPEC_LOCATION" ]; then
            print_box_line "AppSpec Location" "$CD_APPSPEC_LOCATION"
        fi

        if [ -n "$CD_BUILD_COMMAND" ]; then
            print_box_line "Build Command" "$CD_BUILD_COMMAND"
        fi

        if [ -n "$CD_S3_BUCKET" ]; then
            print_box_line "S3 Bucket" "$CD_S3_BUCKET"
        fi
    else
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_YELLOW}No project configuration found${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_DIM}Run 'aws-cd-setup.sh' to create configuration${CD_RESET}"
    fi

    print_box_footer
}

# Main execution
main() {
    clear

    # Display header
    echo -e "${CD_BOLD}${CD_CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║                  AWS CodeDeploy Information & Status                      ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${CD_RESET}"

    # Show active configuration
    display_config_summary

    # Determine what to display
    if [ "$CONFIG_LOADED" = true ]; then
        # Show project-specific CodeDeploy info
        display_project_config
        display_application_info "$CD_APPLICATION_NAME" "$AWS_REGION"
        display_deployment_group_info "$CD_APPLICATION_NAME" "$CD_DEPLOYMENT_GROUP" "$AWS_REGION"
        display_recent_deployments "$CD_APPLICATION_NAME" "$CD_DEPLOYMENT_GROUP" "$AWS_REGION" 5
        display_target_instances "$CD_APPLICATION_NAME" "$CD_DEPLOYMENT_GROUP" "$AWS_REGION"

    elif is_filtering_by_project; then
        # Try to find application by project name convention
        local app_name="${PROJECT_NAME}-app-${ENVIRONMENT}"

        prompt_info "Attempting to find CodeDeploy application: $app_name"
        echo ""

        if cd_application_exists "$app_name" "$AWS_REGION"; then
            display_application_info "$app_name" "$AWS_REGION"

            # Try to find deployment group
            local dg_name="${PROJECT_NAME}-dg-${ENVIRONMENT}"
            if cd_deployment_group_exists "$app_name" "$dg_name" "$AWS_REGION"; then
                display_deployment_group_info "$app_name" "$dg_name" "$AWS_REGION"
                display_recent_deployments "$app_name" "$dg_name" "$AWS_REGION" 5
                display_target_instances "$app_name" "$dg_name" "$AWS_REGION"
            else
                echo ""
                prompt_warning "No deployment group found for this application"
            fi
        else
            echo ""
            prompt_error "No CodeDeploy application found for project: $PROJECT_NAME"
            echo ""
            echo -e "${CD_DIM}Run 'aws-cd-setup.sh' to create a CodeDeploy application${CD_RESET}"
        fi

    else
        # Show all applications in region
        prompt_info "Listing all CodeDeploy applications in $AWS_REGION"
        echo ""

        local all_apps=$(aws deploy list-applications \
            --region "$AWS_REGION" \
            --query 'applications' \
            --output text 2>/dev/null)

        if [ -n "$all_apps" ]; then
            for app in $all_apps; do
                display_application_info "$app" "$AWS_REGION"

                # List deployment groups for this app
                local dgs=$(aws deploy list-deployment-groups \
                    --application-name "$app" \
                    --region "$AWS_REGION" \
                    --query 'deploymentGroups' \
                    --output text 2>/dev/null)

                for dg in $dgs; do
                    display_deployment_group_info "$app" "$dg" "$AWS_REGION"
                    display_recent_deployments "$app" "$dg" "$AWS_REGION" 3
                done
                echo ""
            done
        else
            prompt_warning "No CodeDeploy applications found in $AWS_REGION"
            echo ""
            echo -e "${CD_DIM}Run 'aws-cd-setup.sh' to create a CodeDeploy application${CD_RESET}"
        fi
    fi

    echo ""
    echo -e "${CD_GREEN}✓${CD_RESET} ${CD_BOLD}Information display complete${CD_RESET}"
    echo ""
}

# Run main
main
