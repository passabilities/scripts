#!/bin/bash

# AWS CodeDeploy + CodePipeline Unified Setup Script
# Creates CodeDeploy application, deployment group, CodeBuild project, and CodePipeline

# Note: We don't use 'set -e' because our prompt functions return 1 for "no"
# which is a valid response, not an error. We handle errors explicitly instead.

# Get script directory and find library paths (resolve symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/lib"

# Source libraries
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/config-prompt"
source "${LIB_DIR}/codedeploy"
source "${LIB_DIR}/codepipeline"

# Branch to environment mapping
get_environment_from_branch() {
    local branch=$1
    case "$branch" in
        main) echo "production" ;;
        staging) echo "staging" ;;
        develop) echo "development" ;;
        *) echo "development" ;;  # default fallback
    esac
}

# Determine if we're setting up from within a project or standalone
PROJECT_ROOT="$(pwd)"
CONFIG_LOADED=false

SKIP_CODEDEPLOY_CONFIG=false

if load_cd_config; then
    CONFIG_LOADED=true
    PROJECT_ROOT="$CD_PROJECT_ROOT"

    echo ""
    prompt_warning "CodeDeploy configuration already exists in this project"
    echo ""

    # Display existing configuration
    echo -e "${CD_DIM}Current CodeDeploy Configuration:${CD_RESET}"
    echo -e "  Application: ${CD_GREEN}${CD_APPLICATION_NAME}${CD_RESET}"
    echo -e "  Compute Platform: ${CD_GREEN}${CD_COMPUTE_PLATFORM}${CD_RESET}"
    echo -e "  Service Role: ${CD_GREEN}${CD_SERVICE_ROLE_NAME}${CD_RESET}"
    if [ "$CD_COMPUTE_PLATFORM" = "Server" ]; then
        echo -e "  Instance Profile: ${CD_GREEN}${CD_INSTANCE_PROFILE_NAME}${CD_RESET}"
        echo -e "  Target Type: ${CD_GREEN}${CD_TARGET_TYPE}${CD_RESET}"
        if [ "$CD_TARGET_TYPE" = "tags" ]; then
            echo -e "  Target Tag: ${CD_GREEN}${CD_TARGET_VALUE}${CD_RESET}"
        else
            echo -e "  Auto Scaling Group: ${CD_GREEN}${CD_TARGET_VALUE}${CD_RESET}"
        fi
    fi
    echo -e "  S3 Bucket: ${CD_GREEN}${CD_S3_BUCKET}${CD_RESET}"
    echo ""

    if ! prompt_confirm RECONFIGURE "Do you want to reconfigure CodeDeploy?" "no"; then
        prompt_info "Keeping existing CodeDeploy configuration"
        SKIP_CODEDEPLOY_CONFIG=true

        # Check if they just want to add more pipelines
        echo ""
        if prompt_confirm QUICK_ADD_PIPELINE "Do you want to add pipelines for additional branches?" "yes"; then
            # Set flag to skip wizard and go straight to pipeline addition
            QUICK_PIPELINE_MODE=true
        fi
    fi
    echo ""
fi

# Detect project type (always do this, regardless of config state)
PROJECT_TYPE=$(detect_project_type "$PROJECT_ROOT")

# Quick mode: Add pipelines to existing configuration
quick_add_pipelines() {
    clear
    echo -e "${CD_BOLD}${CD_CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║              Add Branch Pipelines - Quick Mode                           ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${CD_RESET}"
    echo ""

    prompt_info "Adding pipelines to existing CodeDeploy application: ${CD_GREEN}${CD_APPLICATION_NAME}${CD_RESET}"
    echo ""

    # Check which pipelines already exist
    prompt_info "Checking for existing pipelines..."
    local existing_pipelines=$(aws codepipeline list-pipelines \
        --region "$AWS_REGION" \
        --query "pipelines[?starts_with(name, '${PROJECT_NAME}-')].name" \
        --output text 2>/dev/null || echo "")

    local configured_branches=()
    for pipeline in $existing_pipelines; do
        # Extract branch name from pipeline name (format: project-branch-pipeline)
        if [[ "$pipeline" =~ ^${PROJECT_NAME}-(main|staging|develop)-pipeline$ ]]; then
            local branch="${BASH_REMATCH[1]}"
            configured_branches+=("$branch")
            echo -e "  ${CD_DIM}✓ Found: ${branch} → ${pipeline}${CD_RESET}"
        fi
    done

    echo ""

    # Get available branches
    local available_branches=()
    for branch in "main" "staging" "develop"; do
        local already_configured=false
        for configured in "${configured_branches[@]}"; do
            if [ "$branch" = "$configured" ]; then
                already_configured=true
                break
            fi
        done

        if [ "$already_configured" = false ]; then
            available_branches+=("$branch")
        fi
    done

    if [ ${#available_branches[@]} -eq 0 ]; then
        prompt_success "All standard branches (main, staging, develop) already have pipelines!"
        echo ""
        return 0
    fi

    # Load necessary configuration from existing setup
    # IMPORTANT: Always call create_*_service_role functions instead of querying AWS directly
    # These functions update trust policies if the role exists, preventing AssumeRole errors
    local BUILD_ROLE_NAME="${PROJECT_NAME}-codebuild-role"
    prompt_info "Verifying CodeBuild role and trust policy..."
    local BUILD_ROLE_ARN=$(create_codebuild_service_role "$BUILD_ROLE_NAME" "$AWS_REGION" "$PROJECT_NAME")

    if [ -z "$BUILD_ROLE_ARN" ]; then
        prompt_error "Could not find or create CodeBuild role. Please run full setup first."
        exit 1
    fi

    local PIPELINE_ROLE_NAME="${PROJECT_NAME}-codepipeline-role"
    prompt_info "Verifying CodePipeline role and trust policy..."
    local PIPELINE_ROLE_ARN=$(create_codepipeline_service_role "$PIPELINE_ROLE_NAME" "$AWS_REGION" "$PROJECT_NAME")

    if [ -z "$PIPELINE_ROLE_ARN" ]; then
        prompt_error "Could not find or create CodePipeline role. Please run full setup first."
        exit 1
    fi

    prompt_success "IAM roles verified and updated"
    echo ""

    # Get source configuration from first existing pipeline (if any)
    if [ ${#configured_branches[@]} -gt 0 ]; then
        local first_pipeline="${PROJECT_NAME}-${configured_branches[0]}-pipeline"
        local pipeline_json=$(aws codepipeline get-pipeline \
            --name "$first_pipeline" \
            --region "$AWS_REGION" \
            --output json 2>/dev/null)

        SOURCE_TYPE=$(echo "$pipeline_json" | jq -r '.pipeline.stages[0].actions[0].actionTypeId.provider')
        if [ "$SOURCE_TYPE" = "CodeStarSourceConnection" ]; then
            SOURCE_TYPE="GitHub"
            CODESTAR_CONNECTION_ARN=$(echo "$pipeline_json" | jq -r '.pipeline.stages[0].actions[0].configuration.ConnectionArn')
            REPO_ID=$(echo "$pipeline_json" | jq -r '.pipeline.stages[0].actions[0].configuration.FullRepositoryId')
        fi

        # Get build configuration
        local build_project="${PROJECT_NAME}-${configured_branches[0]}-build"
        local build_json=$(aws codebuild batch-get-projects \
            --names "$build_project" \
            --region "$AWS_REGION" \
            --output json 2>/dev/null)

        BUILD_COMPUTE_TYPE=$(echo "$build_json" | jq -r '.projects[0].environment.computeType')
        BUILD_IMAGE=$(echo "$build_json" | jq -r '.projects[0].environment.image')
    else
        # No existing pipelines, need to configure from scratch
        prompt_error "No existing pipelines found. Please run full setup wizard first."
        exit 1
    fi

    # Show available branches
    echo -e "${CD_DIM}Available branches to add:${CD_RESET}"
    for branch in "${available_branches[@]}"; do
        local env=$(get_environment_from_branch "$branch")
        echo -e "  ${CD_GREEN}•${CD_RESET} ${CD_BOLD}$branch${CD_RESET} → ${env} environment"
    done
    echo ""

    # Loop to add pipelines
    for branch in "${available_branches[@]}"; do
        if prompt_confirm ADD_THIS_BRANCH "Add pipeline for ${CD_BOLD}${branch}${CD_RESET} branch?" "yes"; then
            BRANCH_BUILD_PROJECT_NAME="${PROJECT_NAME}-${branch}-build"
            BRANCH_PIPELINE_NAME="${PROJECT_NAME}-${branch}-pipeline"
            BRANCH_ENVIRONMENT=$(get_environment_from_branch "$branch")
            BRANCH_DEPLOYMENT_GROUP="${PROJECT_NAME}-dg-${BRANCH_ENVIRONMENT}"

            echo ""
            prompt_info "Creating CodeBuild project: $BRANCH_BUILD_PROJECT_NAME..."
            BRANCH_BUILD_PROJECT=$(create_codebuild_project \
                "$BRANCH_BUILD_PROJECT_NAME" \
                "$BUILD_ROLE_ARN" \
                "buildspec.yml" \
                "$BUILD_COMPUTE_TYPE" \
                "$BUILD_IMAGE" \
                "$AWS_REGION" \
                "$PROJECT_NAME" \
                "$branch")

            if [ -n "$BRANCH_BUILD_PROJECT" ]; then
                prompt_success "CodeBuild project created"
            else
                prompt_error "Failed to create CodeBuild project"
                continue
            fi

            echo ""
            prompt_info "Creating CodePipeline: $BRANCH_PIPELINE_NAME..."
            local SOURCE_CONFIG_JSON=$(cat <<EOF
{
  "type": "$SOURCE_TYPE",
  "repo": "$REPO_ID",
  "branch": "$branch",
  "connection_arn": "$CODESTAR_CONNECTION_ARN"
}
EOF
)

            BRANCH_PIPELINE=$(create_pipeline \
                "$BRANCH_PIPELINE_NAME" \
                "$PIPELINE_ROLE_ARN" \
                "$CD_S3_BUCKET" \
                "$SOURCE_CONFIG_JSON" \
                "$BRANCH_BUILD_PROJECT_NAME" \
                "$CD_APPLICATION_NAME" \
                "$BRANCH_DEPLOYMENT_GROUP" \
                "$AWS_REGION" \
                "$PROJECT_NAME")

            if [ -n "$BRANCH_PIPELINE" ]; then
                prompt_success "Pipeline created for branch: $branch"
            else
                prompt_error "Failed to create pipeline"
            fi
            echo ""
        fi
    done

    echo ""
    prompt_success "Pipeline addition complete!"
    echo ""
}

# Main configuration wizard
main() {
    if [ "$SKIP_CODEDEPLOY_CONFIG" = "false" ]; then
        clear
    fi

    echo -e "${CD_BOLD}${CD_CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║         AWS CodeDeploy + CodePipeline Unified Setup Wizard               ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${CD_RESET}"
    echo ""

    if [ "$SKIP_CODEDEPLOY_CONFIG" = "true" ]; then
        prompt_info "Proceeding with CodeBuild and CodePipeline setup"
        echo "  • CodeBuild project for building your application"
        echo "  • CodePipeline for automated CI/CD"
    else
        prompt_info "This wizard will set up:"
        echo "  • CodeDeploy application and deployment group"
        echo "  • CodeBuild project for building your application"
        echo "  • CodePipeline for automated CI/CD"
        echo "  • All necessary IAM roles and permissions"
    fi
    echo ""

    # ============================================================================
    # PART A: CODEDEPLOY CONFIGURATION
    # ============================================================================

    if [ "$SKIP_CODEDEPLOY_CONFIG" = "false" ]; then

    # Step 1: AWS Configuration
    prompt_header "AWS Configuration" "Select region and project settings"

    # Load existing AWS config or prompt
    if ! load_existing_config; then
        # No AWS config, need to set it up
        if ! prompt_select_or_custom AWS_REGION \
            "AWS Region" \
            "us-east-1" \
            "us-east-1" "us-east-2" "us-west-1" "us-west-2" \
            "eu-west-1" "eu-central-1" "ap-southeast-1" "ap-northeast-1"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi

        # Auto-detect project name
        local detected_project_name=$(detect_project_name "$PROJECT_ROOT")

        if [ -n "$detected_project_name" ]; then
            echo -e "${CD_DIM}Detected project name: ${CD_GREEN}${detected_project_name}${CD_RESET}"
        fi

        if ! prompt_text PROJECT_NAME \
            "Project name (lowercase, no spaces)" \
            "$detected_project_name" \
            "^[a-z0-9-]+$"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi
    else
        # Have AWS config, show and allow changes
        echo -e "${CD_DIM}Current AWS Configuration:${CD_RESET}"
        echo -e "  Region: ${CD_GREEN}${AWS_REGION}${CD_RESET}"
        echo -e "  Project: ${CD_GREEN}${PROJECT_NAME}${CD_RESET}"
        echo ""

        if ! prompt_confirm USE_AWS_CONFIG "Use this AWS configuration?" "yes"; then
            # Allow customization
            echo ""

            if ! prompt_select_or_custom AWS_REGION \
                "AWS Region" \
                "$AWS_REGION" \
                "us-east-1" "us-east-2" "us-west-1" "us-west-2" \
                "eu-west-1" "eu-central-1" "ap-southeast-1" "ap-northeast-1"; then
                prompt_error "Failed to read input. Exiting."
                exit 1
            fi

            if ! prompt_text PROJECT_NAME \
                "Project name (lowercase, no spaces)" \
                "$PROJECT_NAME" \
                "^[a-z0-9-]+$"; then
                prompt_error "Failed to read input. Exiting."
                exit 1
            fi
        fi
    fi

    echo ""

    # Step 2: Branch Selection
    prompt_header "Branch Configuration" "Select which branches to create pipelines for"

    echo -e "${CD_DIM}Branches map to environments:${CD_RESET}"
    echo -e "  ${CD_GREEN}main${CD_RESET} → production"
    echo -e "  ${CD_GREEN}staging${CD_RESET} → staging"
    echo -e "  ${CD_GREEN}develop${CD_RESET} → development"
    echo ""

    branch_options=("All branches (main, staging, develop)" "main only" "staging only" "develop only" "Custom selection")
    if ! prompt_select BRANCH_SELECTION "Which branches?" 0 "${branch_options[@]}"; then
        prompt_error "Failed to read input. Exiting."
        exit 1
    fi

    # Set up BRANCHES array based on selection
    BRANCHES=()
    case "$BRANCH_SELECTION" in
        "All branches (main, staging, develop)")
            BRANCHES=("main" "staging" "develop")
            ;;
        "main only")
            BRANCHES=("main")
            ;;
        "staging only")
            BRANCHES=("staging")
            ;;
        "develop only")
            BRANCHES=("develop")
            ;;
        "Custom selection")
            echo ""
            prompt_info "Select branches to set up (you can select multiple):"

            if prompt_confirm ADD_MAIN "Set up pipeline for main branch?" "yes"; then
                BRANCHES+=("main")
            fi
            if prompt_confirm ADD_STAGING "Set up pipeline for staging branch?" "yes"; then
                BRANCHES+=("staging")
            fi
            if prompt_confirm ADD_DEVELOP "Set up pipeline for develop branch?" "yes"; then
                BRANCHES+=("develop")
            fi

            if [ ${#BRANCHES[@]} -eq 0 ]; then
                prompt_error "At least one branch must be selected"
                exit 1
            fi
            ;;
    esac

    echo ""
    prompt_success "Selected branches: ${BRANCHES[*]}"
    echo ""

    # Step 3: Compute Platform
    prompt_header "Compute Platform" "Select your deployment target"

    platform_options=("EC2/On-Premises" "AWS Lambda" "Amazon ECS")
    if ! prompt_select CD_COMPUTE_PLATFORM "Compute platform" 0 "${platform_options[@]}"; then
        prompt_error "Failed to read input. Exiting."
        exit 1
    fi

    # Map display name to AWS API value
    case "$CD_COMPUTE_PLATFORM" in
        "EC2/On-Premises") CD_COMPUTE_PLATFORM="Server" ;;
        "AWS Lambda") CD_COMPUTE_PLATFORM="Lambda" ;;
        "Amazon ECS") CD_COMPUTE_PLATFORM="ECS" ;;
    esac

    echo ""

    # Step 4: Application Name
    prompt_header "Application Name" "Name for your CodeDeploy application"

    echo -e "${CD_DIM}Application is shared across all environments${CD_RESET}"
    echo ""

    local default_app_name="${PROJECT_NAME}-app"
    if ! prompt_text CD_APPLICATION_NAME \
        "Application name" \
        "$default_app_name" \
        "^[a-zA-Z0-9_-]+$"; then
        prompt_error "Failed to read input. Exiting."
        exit 1
    fi

    echo ""

    # Step 5: Deployment Groups
    prompt_header "Deployment Groups" "One deployment group per environment"

    echo -e "${CD_DIM}Will create deployment groups for:${CD_RESET}"
    echo -e "  ${CD_GREEN}${PROJECT_NAME}-dg-production${CD_RESET}"
    echo -e "  ${CD_GREEN}${PROJECT_NAME}-dg-staging${CD_RESET}"
    echo -e "  ${CD_GREEN}${PROJECT_NAME}-dg-development${CD_RESET}"
    echo ""

    # Store deployment group names
    CD_DEPLOYMENT_GROUP_PRODUCTION="${PROJECT_NAME}-dg-production"
    CD_DEPLOYMENT_GROUP_STAGING="${PROJECT_NAME}-dg-staging"
    CD_DEPLOYMENT_GROUP_DEVELOPMENT="${PROJECT_NAME}-dg-development"

    # Step 6: Deployment Configuration
    prompt_header "Deployment Configuration" "How to deploy across instances"

    echo -e "${CD_DIM}Same configuration will be used for all environments${CD_RESET}"
    echo ""

    if [ "$CD_COMPUTE_PLATFORM" = "Server" ]; then
        deployment_config_options=(
            "CodeDeployDefault.OneAtATime"
            "CodeDeployDefault.HalfAtATime"
            "CodeDeployDefault.AllAtOnce"
        )
        if ! prompt_select CD_DEPLOYMENT_CONFIG \
            "Deployment configuration" \
            0 \
            "${deployment_config_options[@]}"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi
    elif [ "$CD_COMPUTE_PLATFORM" = "Lambda" ]; then
        deployment_config_options=(
            "CodeDeployDefault.LambdaCanary10Percent5Minutes"
            "CodeDeployDefault.LambdaLinear10PercentEvery1Minute"
            "CodeDeployDefault.LambdaAllAtOnce"
        )
        if ! prompt_select CD_DEPLOYMENT_CONFIG \
            "Deployment configuration" \
            0 \
            "${deployment_config_options[@]}"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi
    else  # ECS
        deployment_config_options=(
            "CodeDeployDefault.ECSCanary10Percent5Minutes"
            "CodeDeployDefault.ECSLinear10PercentEvery1Minute"
            "CodeDeployDefault.ECSAllAtOnce"
        )
        if ! prompt_select CD_DEPLOYMENT_CONFIG \
            "Deployment configuration" \
            0 \
            "${deployment_config_options[@]}"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi
    fi

    echo ""

    # Step 6: Service Role
    prompt_header "Service Role" "IAM role for CodeDeploy"

    CD_SERVICE_ROLE_NAME="${CD_APPLICATION_NAME}-service-role"
    prompt_info "Service role: ${CD_GREEN}${CD_SERVICE_ROLE_NAME}${CD_RESET}"
    echo ""

    # Step 7: Target Configuration (EC2 only)
    if [ "$CD_COMPUTE_PLATFORM" = "Server" ]; then
        prompt_header "Target Configuration" "How to identify deployment targets"

        target_options=("Auto Scaling Groups" "EC2 Tags")
        if ! prompt_select CD_TARGET_TYPE "Target type" 0 "${target_options[@]}"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi

        # Map display name to internal value
        case "$CD_TARGET_TYPE" in
            "EC2 Tags") CD_TARGET_TYPE="tags" ;;
            "Auto Scaling Groups") CD_TARGET_TYPE="asg" ;;
        esac

        echo ""

        if [ "$CD_TARGET_TYPE" = "tags" ]; then
            # Configure EC2 tags
            if ! prompt_text CD_TARGET_KEY \
                "Tag key" \
                "Name" \
                "^[a-zA-Z0-9:/_. -]+$"; then
                prompt_error "Failed to read input. Exiting."
                exit 1
            fi

            local default_tag_value="${PROJECT_NAME}"
            if ! prompt_text CD_TARGET_VALUE \
                "Tag value (will be used for all environments)" \
                "$default_tag_value"; then
                prompt_error "Failed to read input. Exiting."
                exit 1
            fi

            # Format for AWS CLI: {Key=Name,Value=foo,Type=KEY_AND_VALUE}
            CD_TARGET_VALUE="{Key=${CD_TARGET_KEY},Value=${CD_TARGET_VALUE},Type=KEY_AND_VALUE}"
        else
            # Auto Scaling Groups
            prompt_info "Checking for existing Auto Scaling Groups..."

            existing_asgs=$(aws autoscaling describe-auto-scaling-groups \
                --region "$AWS_REGION" \
                --query 'AutoScalingGroups[].AutoScalingGroupName' \
                --output text 2>/dev/null || echo "")

            echo ""

            # Build selection options: existing ASGs + "Create new" option
            asg_options=()
            if [ -n "$existing_asgs" ]; then
                for asg in $existing_asgs; do
                    asg_options+=("$asg")
                done
            fi
            asg_options+=("Select separate ASGs for production/non-production")
            asg_options+=("Create new Auto Scaling Groups")

            # Single selection prompt with arrow keys
            if ! prompt_select CD_TARGET_VALUE \
                "Auto Scaling Group" \
                0 \
                "${asg_options[@]}"; then
                prompt_error "Failed to read input. Exiting."
                exit 1
            fi

            # If user chose to select separate ASGs
            if [ "$CD_TARGET_VALUE" = "Select separate ASGs for production/non-production" ]; then
                echo ""
                prompt_info "Select Auto Scaling Group for production environment (main branch):"
                if ! prompt_select ASG_PROD_NAME \
                    "Production ASG" \
                    0 \
                    $existing_asgs; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                echo ""
                prompt_info "Select Auto Scaling Group for non-production environments (staging/develop branches):"
                if ! prompt_select ASG_NONPROD_NAME \
                    "Non-production ASG" \
                    0 \
                    $existing_asgs; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                CREATE_NEW_ASGS="no"
                USE_SEPARATE_ASGS="yes"
                CD_TARGET_VALUE="$ASG_PROD_NAME,$ASG_NONPROD_NAME"

                echo ""
                prompt_success "Production: $ASG_PROD_NAME"
                prompt_success "Non-production: $ASG_NONPROD_NAME"

            # If user chose to create new, configure and create ASGs
            elif [ "$CD_TARGET_VALUE" = "Create new Auto Scaling Groups" ]; then
                echo ""
                prompt_header "Auto Scaling Group Setup" "Creating 2 ASGs: production and non-production"
                echo ""
                prompt_info "You'll create:"
                echo -e "  ${CD_GREEN}•${CD_RESET} ${CD_BOLD}${PROJECT_NAME}-production-asg${CD_RESET} (for main branch/production)"
                echo -e "  ${CD_GREEN}•${CD_RESET} ${CD_BOLD}${PROJECT_NAME}-nonprod-asg${CD_RESET} (for staging and develop branches)"
                echo ""

                CREATE_NEW_ASGS="yes"
                ASG_PROD_NAME="${PROJECT_NAME}-production-asg"
                ASG_NONPROD_NAME="${PROJECT_NAME}-nonprod-asg"

                # Source the codedeploy library for ASG functions
                source "${LIB_DIR}/codedeploy"

                # Launch Template Configuration
                prompt_header "Launch Template" "Configure EC2 instances for both ASGs"

                # Check for existing launch templates
                prompt_info "Looking for existing launch templates..."
                local existing_templates=$(list_launch_templates "$AWS_REGION")

                local CREATE_NEW_TEMPLATE="no"
                local SELECTED_TEMPLATE_ID=""

                if [ -z "$existing_templates" ]; then
                    prompt_warning "No existing launch templates found"
                    echo ""
                    prompt_info "A new launch template will be created"
                    CREATE_NEW_TEMPLATE="yes"
                else
                    echo -e "${CD_DIM}Found existing launch templates:${CD_RESET}"

                    # Build selection options
                    local template_options=()
                    local template_ids=()

                    while IFS=$'\t' read -r template_id template_name creation_date; do
                        local template_info=$(get_launch_template_info "$template_id" "$AWS_REGION")
                        local ami_id=$(echo "$template_info" | awk '{print $1}')
                        local instance_type=$(echo "$template_info" | awk '{print $2}')

                        echo -e "  ${CD_GREEN}•${CD_RESET} $template_name (${instance_type}, ${ami_id})"
                        template_options+=("$template_name - $instance_type - $template_id")
                        template_ids+=("$template_id")
                    done <<< "$existing_templates"

                    template_options+=("Create new launch template")
                    echo ""

                    local selected_template
                    if ! prompt_select selected_template \
                        "Select launch template" \
                        0 \
                        "${template_options[@]}"; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi

                    if [ "$selected_template" = "Create new launch template" ]; then
                        CREATE_NEW_TEMPLATE="yes"
                    else
                        CREATE_NEW_TEMPLATE="no"
                        # Extract template ID from selection
                        for i in "${!template_options[@]}"; do
                            if [ "${template_options[$i]}" = "$selected_template" ]; then
                                SELECTED_TEMPLATE_ID="${template_ids[$i]}"
                                break
                            fi
                        done
                        prompt_success "Using launch template: $SELECTED_TEMPLATE_ID"
                    fi
                fi

                # If creating new template, prompt for configuration
                if [ "$CREATE_NEW_TEMPLATE" = "yes" ]; then
                    # AMI Selection
                    echo ""
                    prompt_info "Looking up available AMIs..."

                    local al2023_ami=$(get_latest_al2023_ami "$AWS_REGION")
                    local ubuntu_ami=$(get_latest_ubuntu_ami "$AWS_REGION")
                    local al2_ami=$(get_latest_al2_ami "$AWS_REGION")

                    local ami_options=()
                    local ami_ids=()

                    if [ -n "$al2023_ami" ]; then
                        ami_options+=("Amazon Linux 2023 (latest) - $al2023_ami")
                        ami_ids+=("$al2023_ami")
                    fi

                    if [ -n "$ubuntu_ami" ]; then
                        ami_options+=("Ubuntu 22.04 LTS (latest) - $ubuntu_ami")
                        ami_ids+=("$ubuntu_ami")
                    fi

                    if [ -n "$al2_ami" ]; then
                        ami_options+=("Amazon Linux 2 (latest) - $al2_ami")
                        ami_ids+=("$al2_ami")
                    fi

                    ami_options+=("Enter custom AMI ID manually")

                    echo ""
                    local selected_index
                    if ! prompt_select selected_index \
                        "Select AMI to use" \
                        0 \
                        "${ami_options[@]}"; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi

                    if [ "$selected_index" = "Enter custom AMI ID manually" ]; then
                        echo ""
                        if ! prompt_text AMI_ID \
                            "Enter AMI ID" \
                            ""; then
                            prompt_error "Failed to read input. Exiting."
                            exit 1
                        fi
                    else
                        for i in "${!ami_options[@]}"; do
                            if [ "${ami_options[$i]}" = "$selected_index" ]; then
                                AMI_ID="${ami_ids[$i]}"
                                break
                            fi
                        done
                        prompt_success "Selected AMI: $AMI_ID"
                    fi

                    # Instance Type
                    if ! prompt_select_or_custom INSTANCE_TYPE \
                        "Instance type" \
                        "t3.micro" \
                        "t3.micro" "t3.small" "t3.medium" "t3.large" \
                        "t2.micro" "t2.small" "t2.medium"; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi

                    # Security Group
                    echo ""
                    prompt_info "Listing security groups..."
                    local security_groups=$(aws ec2 describe-security-groups \
                        --region "$AWS_REGION" \
                        --query 'SecurityGroups[].[GroupId,GroupName]' \
                        --output text | awk '{printf "%s (%s)\n", $1, $2}')

                    if [ -n "$security_groups" ]; then
                        echo -e "${CD_DIM}Available security groups:${CD_RESET}"
                        echo "$security_groups" | head -5 | while read sg; do
                            echo -e "  ${CD_GREEN}•${CD_RESET} $sg"
                        done
                        echo ""
                    fi

                    if ! prompt_text SECURITY_GROUP_ID \
                        "Security Group ID" \
                        ""; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi

                    # Key Pair
                    echo ""
                    prompt_info "Listing EC2 key pairs..."
                    local key_pairs=$(aws ec2 describe-key-pairs \
                        --region "$AWS_REGION" \
                        --query 'KeyPairs[].KeyName' \
                        --output text | tr '\t' '\n')

                    if [ -n "$key_pairs" ]; then
                        echo -e "${CD_DIM}Available key pairs:${CD_RESET}"
                        echo "$key_pairs" | while read key; do
                            echo -e "  ${CD_GREEN}•${CD_RESET} $key"
                        done
                        echo ""
                    fi

                    if ! prompt_text KEY_NAME \
                        "EC2 Key Pair name" \
                        ""; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi
                fi

                # ASG Configuration (capacity and network)
                echo ""
                prompt_header "ASG Configuration" "Capacity and network settings (applied to both ASGs)"

                # Subnets
                echo ""
                prompt_info "Listing subnets..."
                local subnet_list=$(aws ec2 describe-subnets \
                    --region "$AWS_REGION" \
                    --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock]' \
                    --output text)

                if [ -n "$subnet_list" ]; then
                    local subnet_options=()
                    while IFS=$'\t' read -r subnet_id az cidr; do
                        subnet_options+=("$subnet_id (AZ: $az, CIDR: $cidr)")
                    done <<< "$subnet_list"

                    local selected_subnets
                    if ! prompt_multiselect selected_subnets \
                        "Select subnets for Auto Scaling Groups" \
                        "${subnet_options[@]}"; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi

                    local subnet_ids_array=($(echo "$selected_subnets" | grep -oE 'subnet-[a-z0-9]+'))

                    SUBNET_IDS=""
                    local first=true
                    for subnet_id in "${subnet_ids_array[@]}"; do
                        if [ "$first" = true ]; then
                            SUBNET_IDS="$subnet_id"
                            first=false
                        else
                            SUBNET_IDS="$SUBNET_IDS,$subnet_id"
                        fi
                    done

                    if [ -z "$SUBNET_IDS" ]; then
                        prompt_error "No subnets selected. At least one subnet is required."
                        exit 1
                    fi
                else
                    prompt_error "No subnets found in region $AWS_REGION"
                    exit 1
                fi

                # Production ASG capacity settings
                echo ""
                prompt_header "Production ASG Capacity" "Settings for ${ASG_PROD_NAME}"
                echo ""

                if ! prompt_text PROD_MIN_SIZE \
                    "Minimum instances (production)" \
                    "2"; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                if ! prompt_text PROD_MAX_SIZE \
                    "Maximum instances (production)" \
                    "10"; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                if ! prompt_text PROD_DESIRED_CAPACITY \
                    "Desired instances (production)" \
                    "2"; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                # Non-production ASG capacity settings
                echo ""
                prompt_header "Non-Production ASG Capacity" "Settings for ${ASG_NONPROD_NAME}"
                echo ""

                if ! prompt_text NONPROD_MIN_SIZE \
                    "Minimum instances (non-production)" \
                    "1"; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                if ! prompt_text NONPROD_MAX_SIZE \
                    "Maximum instances (non-production)" \
                    "3"; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                if ! prompt_text NONPROD_DESIRED_CAPACITY \
                    "Desired instances (non-production)" \
                    "1"; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                # Set target value to indicate both ASGs will be created
                CD_TARGET_VALUE="$ASG_PROD_NAME,$ASG_NONPROD_NAME"

                # Load Balancer Configuration
                echo ""
                prompt_header "Load Balancer Configuration" "Distribute traffic across instances"
                echo ""

                if prompt_confirm CREATE_LOAD_BALANCER "Do you want to create an Application Load Balancer?" "yes"; then
                    ALB_NAME="${PROJECT_NAME}-alb"
                    ALB_SG_NAME="${PROJECT_NAME}-alb-sg"
                    TG_PROD_NAME="${PROJECT_NAME}-prod-tg"
                    TG_NONPROD_NAME="${PROJECT_NAME}-nonprod-tg"

                    echo ""
                    prompt_info "Load Balancer: ${CD_GREEN}${ALB_NAME}${CD_RESET}"
                    prompt_info "Target Groups:"
                    echo -e "  ${CD_GREEN}•${CD_RESET} ${TG_PROD_NAME} (production)"
                    echo -e "  ${CD_GREEN}•${CD_RESET} ${TG_NONPROD_NAME} (non-production)"
                    echo ""

                    # ALB Scheme
                    local alb_scheme_options=("internet-facing" "internal")
                    if ! prompt_select ALB_SCHEME \
                        "Load Balancer Scheme" \
                        0 \
                        "${alb_scheme_options[@]}"; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi

                    # Application Port
                    if ! prompt_text APP_PORT \
                        "Application port (target port for health checks)" \
                        "3000"; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi

                    # Health Check Path
                    if ! prompt_text HEALTH_CHECK_PATH \
                        "Health check path" \
                        "/health"; then
                        prompt_error "Failed to read input. Exiting."
                        exit 1
                    fi

                    prompt_info "ALB will listen on port 80 (HTTP) and forward to instances on port ${APP_PORT}"
                else
                    CREATE_LOAD_BALANCER="no"
                fi
            fi
        fi

        echo ""

        # Instance Profile
        CD_INSTANCE_PROFILE_NAME="${CD_APPLICATION_NAME}-instance-profile"
        prompt_info "Instance profile: ${CD_GREEN}${CD_INSTANCE_PROFILE_NAME}${CD_RESET}"
    fi

    echo ""

    # Step 8: Project Configuration
    prompt_header "Project Configuration" "Application-specific settings"

    # Display detected project type (already detected at script start)
    if [ -n "$PROJECT_TYPE" ]; then
        echo -e "${CD_DIM}Detected project type: ${CD_GREEN}${PROJECT_TYPE}${CD_RESET}"
    fi

    # AppSpec location
    local default_appspec="appspec.yml"
    if [ "$CD_COMPUTE_PLATFORM" = "Lambda" ]; then
        default_appspec="appspec.yaml"
    elif [ "$CD_COMPUTE_PLATFORM" = "ECS" ]; then
        default_appspec="appspec.json"
    fi

    if ! prompt_text CD_APPSPEC_LOCATION \
        "AppSpec file location (relative to project root)" \
        "$default_appspec"; then
        prompt_error "Failed to read input. Exiting."
        exit 1
    fi

    # S3 bucket
    echo ""
    prompt_header "S3 Bucket" "Storage for deployment artifacts"

    echo -e "${CD_DIM}Shared bucket for all environments and branches${CD_RESET}"
    echo ""

    local default_bucket="${PROJECT_NAME}-codedeploy"
    if ! prompt_text CD_S3_BUCKET \
        "S3 bucket for deployment artifacts" \
        "$default_bucket" \
        "^[a-z0-9][a-z0-9-]*[a-z0-9]$"; then
        prompt_error "Failed to read input. Exiting."
        exit 1
    fi

    echo ""

    fi  # End of SKIP_CODEDEPLOY_CONFIG check

    # If we skipped CodeDeploy config, we still need to select branches for pipeline
    if [ "$SKIP_CODEDEPLOY_CONFIG" = "true" ]; then
        prompt_header "Branch Selection" "Select which branches to create pipelines for"

        branch_options=(
            "All branches (main, staging, develop)"
            "main only"
            "staging only"
            "develop only"
            "Custom selection"
        )

        if ! prompt_select BRANCH_SELECTION \
            "Which branches do you want to create pipelines for?" \
            0 \
            "${branch_options[@]}"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi

        # Set up BRANCHES array based on selection
        BRANCHES=()
        case "$BRANCH_SELECTION" in
            "All branches (main, staging, develop)")
                BRANCHES=("main" "staging" "develop")
                ;;
            "main only")
                BRANCHES=("main")
                ;;
            "staging only")
                BRANCHES=("staging")
                ;;
            "develop only")
                BRANCHES=("develop")
                ;;
            "Custom selection")
                echo ""
                branch_choices=("main" "staging" "develop")
                if ! prompt_multiselect SELECTED_BRANCHES \
                    "Select branches" \
                    "${branch_choices[@]}"; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                # Convert space-separated to array
                IFS=' ' read -ra BRANCHES <<< "$SELECTED_BRANCHES"
                ;;
        esac

        echo ""
    fi

    # ============================================================================
    # PART B: CODEPIPELINE CONFIGURATION
    # ============================================================================

    prompt_header "CI/CD Pipeline Setup" "Configure automated build and deployment"

    if prompt_confirm SETUP_PIPELINE "Do you want to set up CodePipeline for automated deployments?" "yes"; then
        echo ""

        echo -e "${CD_DIM}Will create one pipeline per selected branch:${CD_RESET}"
        for branch in "${BRANCHES[@]}"; do
            echo -e "  ${CD_GREEN}${PROJECT_NAME}-${branch}-pipeline${CD_RESET}"
        done
        echo ""

        # Step 9: Source Configuration
        prompt_header "Source Configuration" "GitHub Repository"

        # GitHub only - no other options
        SOURCE_TYPE="GitHub"

        echo ""
        prompt_info "GitHub integration requires a CodeStar Connection"
        prompt_info "Checking for existing connections..."

        connections=$(list_codestar_connections "$AWS_REGION")

        if [ -z "$connections" ]; then
            echo ""
            prompt_warning "No active CodeStar connections found"
            prompt_info "You need to create a GitHub connection first:"
            prompt_info "1. Go to: https://console.aws.amazon.com/codesuite/settings/connections"
            prompt_info "2. Create a new connection to GitHub"
            prompt_info "3. Complete the GitHub authorization"
            prompt_info "4. Re-run this script"
            exit 1
        fi

        # Build parallel arrays for connection selection
        connection_options=()
        connection_names=()
        connection_arns=()

        while IFS=$'\t' read -r name arn status; do
            connection_options+=("${name} (${status})")
            connection_names+=("${name}")
            connection_arns+=("${arn}")
        done <<< "$connections"

        echo ""
        if ! prompt_select selected_connection \
            "Select CodeStar connection" \
            0 \
            "${connection_options[@]}"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi

        # Find the index of the selected connection
        selected_index=-1
        for i in "${!connection_options[@]}"; do
            if [ "${connection_options[$i]}" = "$selected_connection" ]; then
                selected_index=$i
                break
            fi
        done

        CODESTAR_CONNECTION_ARN="${connection_arns[$selected_index]}"

        # Auto-detect GitHub repository from git remote
        echo ""
        local detected_repo=""
        if [ -d "$PROJECT_ROOT/.git" ]; then
            local git_remote=$(cd "$PROJECT_ROOT" && git remote get-url origin 2>/dev/null || echo "")
            if [ -n "$git_remote" ]; then
                # Parse owner/repo from various GitHub URL formats
                if [[ "$git_remote" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
                    detected_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
                    echo -e "${CD_DIM}Detected GitHub repository: ${CD_GREEN}${detected_repo}${CD_RESET}"
                fi
            fi
        fi

        if ! prompt_text REPO_ID \
            "Repository (format: owner/repo)" \
            "$detected_repo" \
            "^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+$"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi

        # Extract repo name for display
        REPO_NAME=$(echo "$REPO_ID" | cut -d'/' -f2)

        echo ""

        # Step 10: Build Configuration
        prompt_header "Build Configuration" "Configure CodeBuild settings (shared across all branches)"

        echo ""

        # Build compute type
        compute_options=(
            "BUILD_GENERAL1_SMALL (3 GB memory, 2 vCPUs)"
            "BUILD_GENERAL1_MEDIUM (7 GB memory, 4 vCPUs)"
            "BUILD_GENERAL1_LARGE (15 GB memory, 8 vCPUs)"
        )
        if ! prompt_select selected_compute \
            "Build compute type" \
            1 \
            "${compute_options[@]}"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi

        BUILD_COMPUTE_TYPE=$(echo "$selected_compute" | cut -d' ' -f1)

        echo ""

        # Build image
        image_options=(
            "aws/codebuild/standard:7.0 (Ubuntu, latest)"
            "aws/codebuild/amazonlinux2-x86_64-standard:5.0 (Amazon Linux 2)"
            "aws/codebuild/amazonlinux2-aarch64-standard:3.0 (Amazon Linux 2, ARM)"
        )
        if ! prompt_select selected_image \
            "Build image" \
            0 \
            "${image_options[@]}"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi

        BUILD_IMAGE=$(echo "$selected_image" | cut -d' ' -f1)

        echo ""

        # Step 11: Environment Variables
        prompt_header "Environment Variables" "Configure build and runtime variables"

        echo ""
        echo -e "${CD_DIM}These variables will be stored in SSM Parameter Store for all environments${CD_RESET}"
        prompt_info "Build variables: Available during build (buildspec.yml)"
        prompt_info "Runtime variables: Injected into application at deployment"
        echo ""

        # Build environment variables - DEFAULT VALUES
        echo ""
        prompt_info "Build environment variables - Default values (optional)"
        echo -e "${CD_DIM}Paste your environment variables in KEY=VALUE format${CD_RESET}"
        echo -e "${CD_DIM}Empty values, blank lines, and comments (#) will be skipped${CD_RESET}"
        echo -e "${CD_DIM}Press ${CD_BOLD}Ctrl+D${CD_RESET}${CD_DIM} when done${CD_RESET}"
        echo ""
        echo -e "${CD_DIM}Example:${CD_RESET}"
        echo "  DATABASE_URL=postgres://localhost:5432/db"
        echo "  API_KEY=your-api-key-here"
        echo "  NODE_ENV=production"
        echo ""

        # Associative arrays to store defaults and overrides
        declare -A BUILD_ENV_DEFAULTS
        declare -A BUILD_ENV_PRODUCTION
        declare -A BUILD_ENV_STAGING
        declare -A BUILD_ENV_DEVELOPMENT

        # Read multi-line input until EOF (Ctrl+D)
        local build_env_input=""
        while IFS= read -r line || [ -n "$line" ]; do
            build_env_input+="$line"$'\n'
        done

        # Parse the input line by line (only if there's input)
        local build_count=0
        if [ -n "$build_env_input" ]; then
            while IFS= read -r env_line; do
                # Skip comments and empty lines
                [[ "$env_line" =~ ^[[:space:]]*# ]] && continue
                [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue

                # Extract key and value
                if [[ "$env_line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                    local key="${BASH_REMATCH[1]}"
                    local value="${BASH_REMATCH[2]}"

                    # Skip if value is empty
                    if [ -z "$value" ]; then
                        echo -e "${CD_DIM}  Skipped (empty value): ${key}${CD_RESET}"
                        continue
                    fi

                    BUILD_ENV_DEFAULTS["$key"]="$value"
                    echo -e "${CD_DIM}  ✓ Added: ${CD_GREEN}${key}${CD_RESET}"
                    ((++build_count))
                else
                    # Line didn't match expected format
                    if [ -n "$env_line" ]; then
                        echo -e "${CD_DIM}  Skipped (invalid format): ${env_line}${CD_RESET}"
                    fi
                fi
            done <<< "$build_env_input"
        fi

        if [ $build_count -gt 0 ]; then
            echo -e "${CD_DIM}✓ Accepted $build_count build variable(s)${CD_RESET}"
            echo ""

            # Offer environment-specific overrides
            if prompt_confirm CUSTOMIZE_BUILD_VARS "Customize build variables for specific environments?" "no"; then
                echo ""

                for env in "production" "staging" "development"; do
                    prompt_info "${env^} environment overrides (optional)"
                    echo -e "${CD_DIM}Current defaults that can be overridden:${CD_RESET}"
                    for key in "${!BUILD_ENV_DEFAULTS[@]}"; do
                        echo -e "  ${CD_YELLOW}${key}${CD_RESET}=${BUILD_ENV_DEFAULTS[$key]}"
                    done
                    echo ""
                    echo -e "${CD_DIM}Paste overrides for ${env} (KEY=VALUE format)${CD_RESET}"
                    echo -e "${CD_DIM}Empty values, blank lines, and comments (#) will be skipped${CD_RESET}"
                    echo -e "${CD_DIM}Press ${CD_BOLD}Ctrl+D${CD_RESET}${CD_DIM} when done (or Ctrl+D immediately to skip)${CD_RESET}"
                    echo ""

                    # Read multi-line input until EOF (Ctrl+D)
                    local env_override_input=""
                    while IFS= read -r line || [ -n "$line" ]; do
                        env_override_input+="$line"'\n'
                    done

                    # Parse the input line by line (only if there's input)
                    if [ -n "$env_override_input" ]; then
                        while IFS= read -r env_line; do
                            # Skip comments and empty lines
                            [[ "$env_line" =~ ^[[:space:]]*# ]] && continue
                            [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue

                            # Extract key and value
                            if [[ "$env_line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                                local key="${BASH_REMATCH[1]}"
                                local value="${BASH_REMATCH[2]}"

                                # Skip if value is empty
                                if [ -z "$value" ]; then
                                    echo -e "${CD_DIM}  Skipped (empty value): ${key}${CD_RESET}"
                                    continue
                                fi

                                case "$env" in
                                    "production") BUILD_ENV_PRODUCTION["$key"]="$value" ;;
                                    "staging") BUILD_ENV_STAGING["$key"]="$value" ;;
                                    "development") BUILD_ENV_DEVELOPMENT["$key"]="$value" ;;
                                esac
                                echo -e "${CD_DIM}  ✓ Override set: ${CD_GREEN}${key}${CD_RESET}"
                            else
                                # Line didn't match expected format
                                if [ -n "$env_line" ]; then
                                    echo -e "${CD_DIM}  Skipped (invalid format): ${env_line}${CD_RESET}"
                                fi
                            fi
                        done <<< "$env_override_input"
                    fi
                    echo ""
                done
            fi
        fi

        echo ""

        # Runtime environment variables - DEFAULT VALUES
echo ""
        prompt_info "Runtime environment variables - Default values (optional)"
        echo -e "${CD_DIM}Paste your environment variables in KEY=VALUE format${CD_RESET}"
        echo -e "${CD_DIM}Empty values, blank lines, and comments (#) will be skipped${CD_RESET}"
        echo -e "${CD_DIM}Press ${CD_BOLD}Ctrl+D${CD_RESET}${CD_DIM} when done${CD_RESET}"
        echo ""

        declare -A RUNTIME_ENV_DEFAULTS
        declare -A RUNTIME_ENV_PRODUCTION
        declare -A RUNTIME_ENV_STAGING
        declare -A RUNTIME_ENV_DEVELOPMENT

        # Read multi-line input until EOF (Ctrl+D)
        local runtime_env_input=""
        while IFS= read -r line || [ -n "$line" ]; do
            runtime_env_input+="$line"$'\n'
        done

        # Parse the input line by line (only if there's input)
        local runtime_count=0
        if [ -n "$runtime_env_input" ]; then
            while IFS= read -r env_line; do
                # Skip comments and empty lines
                [[ "$env_line" =~ ^[[:space:]]*# ]] && continue
                [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue

                # Extract key and value
                if [[ "$env_line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                    local key="${BASH_REMATCH[1]}"
                    local value="${BASH_REMATCH[2]}"

                    # Skip if value is empty
                    if [ -z "$value" ]; then
                        echo -e "${CD_DIM}  Skipped (empty value): ${key}${CD_RESET}"
                        continue
                    fi

                    RUNTIME_ENV_DEFAULTS["$key"]="$value"
                    echo -e "${CD_DIM}  ✓ Added: ${CD_GREEN}${key}${CD_RESET}"
                    ((++runtime_count))
                else
                    # Line didn't match expected format
                    if [ -n "$env_line" ]; then
                        echo -e "${CD_DIM}  Skipped (invalid format): ${env_line}${CD_RESET}"
                    fi
                fi
            done <<< "$runtime_env_input"
        fi

        if [ $runtime_count -gt 0 ]; then
            echo -e "${CD_DIM}✓ Accepted $runtime_count runtime variable(s)${CD_RESET}"
            echo ""

            # Offer environment-specific overrides
            if prompt_confirm CUSTOMIZE_RUNTIME_VARS "Customize runtime variables for specific environments?" "no"; then
                echo ""

                for env in "production" "staging" "development"; do
                    prompt_info "${env^} environment overrides (optional)"
                    echo -e "${CD_DIM}Current defaults that can be overridden:${CD_RESET}"
                    for key in "${!RUNTIME_ENV_DEFAULTS[@]}"; do
                        echo -e "  ${CD_YELLOW}${key}${CD_RESET}=${RUNTIME_ENV_DEFAULTS[$key]}"
                    done
                    echo ""
                    echo -e "${CD_DIM}Paste overrides for ${env} (KEY=VALUE format)${CD_RESET}"
                    echo -e "${CD_DIM}Empty values, blank lines, and comments (#) will be skipped${CD_RESET}"
                    echo -e "${CD_DIM}Press ${CD_BOLD}Ctrl+D${CD_RESET}${CD_DIM} when done (or Ctrl+D immediately to skip)${CD_RESET}"
                    echo ""

                    # Read multi-line input until EOF (Ctrl+D)
                    local env_override_input=""
                    while IFS= read -r line || [ -n "$line" ]; do
                        env_override_input+="$line"'\n'
                    done

                    # Parse the input line by line (only if there's input)
                    if [ -n "$env_override_input" ]; then
                        while IFS= read -r env_line; do
                            # Skip comments and empty lines
                            [[ "$env_line" =~ ^[[:space:]]*# ]] && continue
                            [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue

                            # Extract key and value
                            if [[ "$env_line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                                local key="${BASH_REMATCH[1]}"
                                local value="${BASH_REMATCH[2]}"

                                # Skip if value is empty
                                if [ -z "$value" ]; then
                                    echo -e "${CD_DIM}  Skipped (empty value): ${key}${CD_RESET}"
                                    continue
                                fi

                                case "$env" in
                                    "production") RUNTIME_ENV_PRODUCTION["$key"]="$value" ;;
                                    "staging") RUNTIME_ENV_STAGING["$key"]="$value" ;;
                                    "development") RUNTIME_ENV_DEVELOPMENT["$key"]="$value" ;;
                                esac
                                echo -e "${CD_DIM}  ✓ Override set: ${CD_GREEN}${key}${CD_RESET}"
                            else
                                # Line didn't match expected format
                                if [ -n "$env_line" ]; then
                                    echo -e "${CD_DIM}  Skipped (invalid format): ${env_line}${CD_RESET}"
                                fi
                            fi
                        done <<< "$env_override_input"
                    fi
                    echo ""
                done
            fi
        fi

        # Auto-inject NODE_ENV for Node.js projects
        if [[ "$PROJECT_TYPE" =~ ^(nodejs|node)$ ]]; then
            echo ""
            prompt_info "Node.js project detected - automatically setting NODE_ENV"
            echo -e "${CD_DIM}NODE_ENV will be set automatically based on branch:${CD_RESET}"
            echo -e "  main → ${CD_GREEN}NODE_ENV=production${CD_RESET}"
            echo -e "  staging → ${CD_GREEN}NODE_ENV=production${CD_RESET}"
            echo -e "  develop → ${CD_GREEN}NODE_ENV=development${CD_RESET}"

            # Add NODE_ENV to runtime variables (only if not already set)
            if [ -z "${RUNTIME_ENV_PRODUCTION[NODE_ENV]}" ]; then
                RUNTIME_ENV_PRODUCTION["NODE_ENV"]="production"
            fi
            if [ -z "${RUNTIME_ENV_STAGING[NODE_ENV]}" ]; then
                RUNTIME_ENV_STAGING["NODE_ENV"]="production"
            fi
            if [ -z "${RUNTIME_ENV_DEVELOPMENT[NODE_ENV]}" ]; then
                RUNTIME_ENV_DEVELOPMENT["NODE_ENV"]="development"
            fi
        fi

        echo ""

        # Step 13: Build Command for CodeBuild
        prompt_header "Build Configuration" "Define how CodeBuild will build your application"

        # Auto-detect build command based on project type
        default_build_cmd=$(get_default_build_command "$PROJECT_TYPE")

        echo -e "${CD_DIM}Suggested build command for ${PROJECT_TYPE}:${CD_RESET}"
        echo -e "${CD_GREEN}${default_build_cmd}${CD_RESET}"
        echo ""

        if ! prompt_text CODEBUILD_BUILD_COMMAND \
            "Build command for CodeBuild" \
            "$default_build_cmd"; then
            prompt_error "Failed to read input. Exiting."
            exit 1
        fi
    fi

    echo ""

    # ============================================================================
    # PRECHECK VERIFICATION
    # ============================================================================

    prompt_header "Precheck Verification" "Checking for existing resources"
    echo ""

    EXISTING_RESOURCES_FOUND=false

    # Check CodeDeploy Application
    prompt_info "Checking for existing CodeDeploy application..."
    if cd_application_exists "$CD_APPLICATION_NAME" "$AWS_REGION"; then
        prompt_warning "CodeDeploy application already exists: $CD_APPLICATION_NAME"
        echo ""

        # Get existing application configuration
        EXISTING_APP_CONFIG=$(aws deploy get-application \
            --application-name "$CD_APPLICATION_NAME" \
            --region "$AWS_REGION" \
            --output json 2>/dev/null)

        if [ $? -eq 0 ]; then
            EXISTING_PLATFORM=$(echo "$EXISTING_APP_CONFIG" | grep -o '"computePlatform": *"[^"]*"' | cut -d'"' -f4)

            # Display existing configuration
            print_box_header "Existing Application Configuration"
            print_box_line "Application Name" "$CD_APPLICATION_NAME"
            print_box_line "Compute Platform" "$EXISTING_PLATFORM"
            print_box_footer
            echo ""

            # Compare with desired configuration
            if [ "$EXISTING_PLATFORM" != "$CD_COMPUTE_PLATFORM" ]; then
                prompt_warning "Platform mismatch detected!"
                echo "  Existing: ${CD_YELLOW}${EXISTING_PLATFORM}${CD_RESET}"
                echo "  Desired:  ${CD_GREEN}${CD_COMPUTE_PLATFORM}${CD_RESET}"
                echo ""

                prompt_info "CodeDeploy applications cannot change compute platform."
                echo ""

                action_options=("Keep existing platform" "Delete and recreate application")
                if ! prompt_select PLATFORM_ACTION "What would you like to do?" 0 "${action_options[@]}"; then
                    prompt_error "Failed to read input. Exiting."
                    exit 1
                fi

                if [ "$PLATFORM_ACTION" = "Keep existing platform" ]; then
                    # Update our configuration to match existing
                    CD_COMPUTE_PLATFORM="$EXISTING_PLATFORM"
                    prompt_success "Using existing platform: $CD_COMPUTE_PLATFORM"
                else
                    # Delete existing application
                    prompt_warning "This will delete the application and ALL deployment groups!"
                    echo ""

                    if prompt_confirm CONFIRM_DELETE "Are you sure you want to delete $CD_APPLICATION_NAME?" "no"; then
                        prompt_info "Deleting CodeDeploy application: $CD_APPLICATION_NAME"

                        set +e
                        aws deploy delete-application \
                            --application-name "$CD_APPLICATION_NAME" \
                            --region "$AWS_REGION" 2>/dev/null
                        DELETE_RESULT=$?
                        set -e

                        if [ $DELETE_RESULT -eq 0 ]; then
                            prompt_success "Application deleted successfully"
                            sleep 2
                        else
                            prompt_error "Failed to delete application"
                            exit 1
                        fi
                    else
                        prompt_error "Operation cancelled by user"
                        exit 1
                    fi
                fi
            else
                # Platform matches
                prompt_success "Platform matches: $CD_COMPUTE_PLATFORM"
                prompt_info "Will use existing application"
            fi

            EXISTING_RESOURCES_FOUND=true
        else
            prompt_error "Failed to retrieve application configuration"
            exit 1
        fi
    else
        prompt_success "CodeDeploy application name available: $CD_APPLICATION_NAME"
    fi

    echo ""

    # Note: Resource validation for deployment groups, build projects, and pipelines
    # now happens during the creation phase where proper branch-based naming is used

    echo ""

    # ============================================================================
    # SUMMARY AND CONFIRMATION
    # ============================================================================

    prompt_header "Configuration Summary" "Review your settings"

    # CodeDeploy section
    print_box_header "CodeDeploy Configuration"
    print_box_line "Region" "$AWS_REGION"
    print_box_line "Project" "$PROJECT_NAME"
    print_box_line "Compute Platform" "$CD_COMPUTE_PLATFORM"
    print_box_line "Application" "$CD_APPLICATION_NAME"
    echo -e "  ${CD_BOLD}Deployment Groups${CD_RESET}"
    echo -e "    ${CD_DIM}→ ${CD_GREEN}${PROJECT_NAME}-dg-production${CD_RESET}"
    echo -e "    ${CD_DIM}→ ${CD_GREEN}${PROJECT_NAME}-dg-staging${CD_RESET}"
    echo -e "    ${CD_DIM}→ ${CD_GREEN}${PROJECT_NAME}-dg-development${CD_RESET}"
    print_box_line "Deployment Config" "$CD_DEPLOYMENT_CONFIG"
    print_box_line "Service Role" "$CD_SERVICE_ROLE_NAME"

    if [ "$CD_COMPUTE_PLATFORM" = "Server" ]; then
        print_box_line "Instance Profile" "$CD_INSTANCE_PROFILE_NAME"
        print_box_line "Target Type" "$CD_TARGET_TYPE"
        if [ "$CD_TARGET_TYPE" = "tags" ]; then
            print_box_line "Target Tag" "${CD_TARGET_VALUE}"
        else
            if [ "${CREATE_NEW_ASGS:-no}" = "yes" ]; then
                print_box_line "Production ASG" "$ASG_PROD_NAME"
                print_box_line "Non-Prod ASG" "$ASG_NONPROD_NAME"
            else
                print_box_line "Auto Scaling Group" "$CD_TARGET_VALUE"
            fi
        fi
    fi

    print_box_line "AppSpec Location" "$CD_APPSPEC_LOCATION"
    print_box_line "S3 Bucket" "$CD_S3_BUCKET"
    print_box_footer

    # Pipeline section
    if [ "$SETUP_PIPELINE" = "yes" ]; then
        echo ""
        print_box_header "CodePipeline Configuration"
        print_box_line "Source Type" "$SOURCE_TYPE"
        if [ "$SOURCE_TYPE" = "GitHub" ]; then
            print_box_line "Repository" "$REPO_ID"
        else
            print_box_line "Repository" "$REPO_NAME"
        fi
        echo -e "  ${CD_BOLD}Selected Branches${CD_RESET}"
        for branch in "${BRANCHES[@]}"; do
            local env=$(get_environment_from_branch "$branch")
            echo -e "    ${CD_DIM}→ ${CD_GREEN}${branch}${CD_RESET} ${CD_DIM}(${env})${CD_RESET}"
        done
        echo -e "  ${CD_BOLD}Pipelines to Create${CD_RESET}"
        for branch in "${BRANCHES[@]}"; do
            echo -e "    ${CD_DIM}→ ${CD_GREEN}${PROJECT_NAME}-${branch}-pipeline${CD_RESET}"
        done
        echo -e "  ${CD_BOLD}Build Projects to Create${CD_RESET}"
        for branch in "${BRANCHES[@]}"; do
            echo -e "    ${CD_DIM}→ ${CD_GREEN}${PROJECT_NAME}-${branch}-build${CD_RESET}"
        done
        print_box_line "Build Compute" "$BUILD_COMPUTE_TYPE"
        print_box_line "Build Image" "$BUILD_IMAGE"
        print_box_line "Build Command" "$CODEBUILD_BUILD_COMMAND"
        echo ""
        echo -e "  ${CD_BOLD}Shared IAM Roles${CD_RESET} ${CD_DIM}(used by all branches)${CD_RESET}"
        echo -e "    ${CD_DIM}→ CodeBuild: ${CD_GREEN}${PROJECT_NAME}-codebuild-role${CD_RESET}"
        echo -e "    ${CD_DIM}→ CodePipeline: ${CD_GREEN}${PROJECT_NAME}-codepipeline-role${CD_RESET}"
        print_box_footer
    fi

    echo ""

    if ! prompt_confirm PROCEED "Create resources with this configuration?" "yes"; then
        prompt_warning "Setup cancelled by user"
        exit 0
    fi

    # ============================================================================
    # CREATE RESOURCES
    # ============================================================================

    echo ""
    prompt_header "Creating Resources" "Setting up AWS infrastructure"
    echo ""

    prompt_info "This may take several minutes..."
    echo ""

    # PHASE 1: Create CodeDeploy resources (skip if using existing config)
    if [ "$SKIP_CODEDEPLOY_CONFIG" = "false" ]; then
        prompt_header "Phase 1: CodeDeploy Setup" "Creating deployment infrastructure"
        echo ""

    # Create service role
    prompt_info "Creating IAM service role: $CD_SERVICE_ROLE_NAME"
    local service_role_arn=$(create_codedeploy_service_role "$CD_SERVICE_ROLE_NAME" "$AWS_REGION" "$PROJECT_NAME")

    if [ -n "$service_role_arn" ]; then
        prompt_success "Service role created: $service_role_arn"
    else
        prompt_error "Failed to create service role"
        exit 1
    fi

    # Create instance profile (if EC2)
    if [ "$CD_COMPUTE_PLATFORM" = "Server" ]; then
        echo ""
        prompt_info "Creating IAM instance profile: $CD_INSTANCE_PROFILE_NAME"
        local instance_profile_arn=$(create_codedeploy_instance_profile "$CD_INSTANCE_PROFILE_NAME")

        if [ -n "$instance_profile_arn" ]; then
            prompt_success "Instance profile created: $instance_profile_arn"
        else
            prompt_error "Failed to create instance profile"
            exit 1
        fi
    fi

    # Create S3 bucket
    echo ""
    prompt_info "Creating S3 bucket: $CD_S3_BUCKET"

    if aws s3 ls "s3://${CD_S3_BUCKET}" &>/dev/null; then
        prompt_success "S3 bucket already exists and is accessible"
    else
        local create_output
        create_output=$(aws s3 mb "s3://${CD_S3_BUCKET}" --region "$AWS_REGION" 2>&1)
        local create_result=$?

        if [ $create_result -eq 0 ]; then
            # Tag the bucket
            aws s3api put-bucket-tagging \
                --bucket "$CD_S3_BUCKET" \
                --tagging "TagSet=[{Key=Project,Value=$PROJECT_NAME}]" \
                --region "$AWS_REGION" \
                &>/dev/null
            prompt_success "S3 bucket created"
        elif echo "$create_output" | grep -q "BucketAlreadyOwnedByYou"; then
            # Tag existing bucket
            aws s3api put-bucket-tagging \
                --bucket "$CD_S3_BUCKET" \
                --tagging "TagSet=[{Key=Project,Value=$PROJECT_NAME}]" \
                --region "$AWS_REGION" \
                &>/dev/null
            prompt_success "S3 bucket already exists (owned by you)"
        elif echo "$create_output" | grep -q "BucketAlreadyExists"; then
            prompt_warning "Bucket name already taken by another account"
            prompt_error "Please choose a different bucket name"
            exit 1
        else
            prompt_error "Failed to create S3 bucket"
            echo -e "${CD_DIM}Error: $create_output${CD_RESET}"
            exit 1
        fi
    fi

    # Create Auto Scaling Groups if requested
    if [ "${CREATE_NEW_ASGS:-no}" = "yes" ]; then
        echo ""
        prompt_header "Creating Auto Scaling Groups" "Setting up production and non-production ASGs"

        # Create or use launch template
        local LAUNCH_TEMPLATE_ID=""
        if [ "$CREATE_NEW_TEMPLATE" = "yes" ]; then
            echo ""
            prompt_info "Creating launch template: ${PROJECT_NAME}-launch-template"

            LAUNCH_TEMPLATE_ID=$(create_launch_template \
                "${PROJECT_NAME}-launch-template" \
                "$AMI_ID" \
                "$INSTANCE_TYPE" \
                "$SECURITY_GROUP_ID" \
                "$KEY_NAME" \
                "$CD_INSTANCE_PROFILE_ARN" \
                "$AWS_REGION")

            if [ $? -eq 0 ] && [ -n "$LAUNCH_TEMPLATE_ID" ]; then
                prompt_success "Launch template created: $LAUNCH_TEMPLATE_ID"
            else
                prompt_error "Failed to create launch template"
                exit 1
            fi
        else
            LAUNCH_TEMPLATE_ID="$SELECTED_TEMPLATE_ID"
            prompt_info "Using existing launch template: $LAUNCH_TEMPLATE_ID"
        fi

        # Create Load Balancer and Target Groups if requested
        local TG_PROD_ARN=""
        local TG_NONPROD_ARN=""

        if [ "${CREATE_LOAD_BALANCER:-no}" = "yes" ]; then
            echo ""
            prompt_header "Creating Load Balancer" "Setting up ALB and target groups"

            # Get VPC ID from subnets
            local VPC_ID=$(aws ec2 describe-subnets \
                --subnet-ids $(echo "$SUBNET_IDS" | cut -d',' -f1) \
                --region "$AWS_REGION" \
                --query 'Subnets[0].VpcId' \
                --output text)

            # Create ALB Security Group
            echo ""
            prompt_info "Creating ALB security group: $ALB_SG_NAME..."
            local ALB_SG_ID=$(create_alb_security_group \
                "$ALB_SG_NAME" \
                "$VPC_ID" \
                "Security group for Application Load Balancer" \
                "$AWS_REGION")

            if [ -n "$ALB_SG_ID" ]; then
                prompt_success "ALB security group created: $ALB_SG_ID"

                # Add ingress rule for HTTP
                aws ec2 authorize-security-group-ingress \
                    --group-id "$ALB_SG_ID" \
                    --protocol tcp \
                    --port 80 \
                    --cidr 0.0.0.0/0 \
                    --region "$AWS_REGION" \
                    &>/dev/null || true
            else
                prompt_error "Failed to create ALB security group"
                exit 1
            fi

            # Update instance security group to allow traffic from ALB
            echo ""
            prompt_info "Updating instance security group to allow traffic from ALB..."
            aws ec2 authorize-security-group-ingress \
                --group-id "$SECURITY_GROUP_ID" \
                --protocol tcp \
                --port "$APP_PORT" \
                --source-group "$ALB_SG_ID" \
                --region "$AWS_REGION" \
                &>/dev/null || true

            # Create Production Target Group
            echo ""
            prompt_info "Creating production target group: $TG_PROD_NAME..."
            TG_PROD_ARN=$(create_target_group \
                "$TG_PROD_NAME" \
                "$VPC_ID" \
                "$APP_PORT" \
                "HTTP" \
                "$HEALTH_CHECK_PATH" \
                "$AWS_REGION")

            if [ -n "$TG_PROD_ARN" ]; then
                prompt_success "Production target group created"
            else
                prompt_error "Failed to create production target group"
                exit 1
            fi

            # Create Non-Production Target Group
            echo ""
            prompt_info "Creating non-production target group: $TG_NONPROD_NAME..."
            TG_NONPROD_ARN=$(create_target_group \
                "$TG_NONPROD_NAME" \
                "$VPC_ID" \
                "$APP_PORT" \
                "HTTP" \
                "$HEALTH_CHECK_PATH" \
                "$AWS_REGION")

            if [ -n "$TG_NONPROD_ARN" ]; then
                prompt_success "Non-production target group created"
            else
                prompt_error "Failed to create non-production target group"
                exit 1
            fi

            # Create Application Load Balancer
            echo ""
            prompt_info "Creating Application Load Balancer: $ALB_NAME..."
            local ALB_ARN=$(create_application_load_balancer \
                "$ALB_NAME" \
                "$ALB_SG_ID" \
                "$SUBNET_IDS" \
                "$ALB_SCHEME" \
                "$AWS_REGION")

            if [ -n "$ALB_ARN" ]; then
                prompt_success "Application Load Balancer created"

                # Get ALB DNS name
                local ALB_DNS=$(aws elbv2 describe-load-balancers \
                    --load-balancer-arns "$ALB_ARN" \
                    --region "$AWS_REGION" \
                    --query 'LoadBalancers[0].DNSName' \
                    --output text)

                prompt_info "ALB DNS: ${CD_GREEN}${ALB_DNS}${CD_RESET}"
            else
                prompt_error "Failed to create Application Load Balancer"
                exit 1
            fi

            # Create Listener (default to production target group)
            echo ""
            prompt_info "Creating ALB listener on port 80..."
            local LISTENER_ARN=$(create_alb_listener \
                "$ALB_ARN" \
                "$TG_PROD_ARN" \
                "80" \
                "HTTP" \
                "$AWS_REGION")

            if [ -n "$LISTENER_ARN" ]; then
                prompt_success "ALB listener created"
            else
                prompt_error "Failed to create ALB listener"
                exit 1
            fi

            echo ""
            prompt_success "Load Balancer setup complete!"
        fi

        # Create production ASG
        echo ""
        prompt_info "Creating production Auto Scaling Group: $ASG_PROD_NAME"
        echo -e "${CD_DIM}  Min: $PROD_MIN_SIZE, Max: $PROD_MAX_SIZE, Desired: $PROD_DESIRED_CAPACITY${CD_RESET}"

        local created_asg_prod=$(create_asg \
            "$ASG_PROD_NAME" \
            "$LAUNCH_TEMPLATE_ID" \
            "$SUBNET_IDS" \
            "$PROD_MIN_SIZE" \
            "$PROD_MAX_SIZE" \
            "$PROD_DESIRED_CAPACITY" \
            "$TG_PROD_ARN" \
            "$AWS_REGION")

        if [ $? -eq 0 ] && [ -n "$created_asg_prod" ]; then
            prompt_success "Production ASG created: $ASG_PROD_NAME"
        else
            prompt_error "Failed to create production ASG"
            exit 1
        fi

        # Create non-production ASG
        echo ""
        prompt_info "Creating non-production Auto Scaling Group: $ASG_NONPROD_NAME"
        echo -e "${CD_DIM}  Min: $NONPROD_MIN_SIZE, Max: $NONPROD_MAX_SIZE, Desired: $NONPROD_DESIRED_CAPACITY${CD_RESET}"

        local created_asg_nonprod=$(create_asg \
            "$ASG_NONPROD_NAME" \
            "$LAUNCH_TEMPLATE_ID" \
            "$SUBNET_IDS" \
            "$NONPROD_MIN_SIZE" \
            "$NONPROD_MAX_SIZE" \
            "$NONPROD_DESIRED_CAPACITY" \
            "$TG_NONPROD_ARN" \
            "$AWS_REGION")

        if [ $? -eq 0 ] && [ -n "$created_asg_nonprod" ]; then
            prompt_success "Non-production ASG created: $ASG_NONPROD_NAME"
        else
            prompt_error "Failed to create non-production ASG"
            exit 1
        fi

        echo ""
        prompt_success "Both Auto Scaling Groups created successfully"
    fi

    # Create CodeDeploy application
    echo ""
    prompt_info "Creating CodeDeploy application: $CD_APPLICATION_NAME"

    if cd_application_exists "$CD_APPLICATION_NAME" "$AWS_REGION"; then
        prompt_warning "Application already exists"
    else
        aws deploy create-application \
            --application-name "$CD_APPLICATION_NAME" \
            --compute-platform "$CD_COMPUTE_PLATFORM" \
            --tags Key=Project,Value=$PROJECT_NAME \
            --region "$AWS_REGION" \
            &>/dev/null

        if [ $? -eq 0 ]; then
            prompt_success "Application created"
        else
            prompt_error "Failed to create application"
            exit 1
        fi
    fi

    # Create deployment groups for all three environments
    echo ""
    prompt_info "Creating deployment groups for all environments..."

    for env in "production" "staging" "development"; do
        local dg_name="${PROJECT_NAME}-dg-${env}"
        echo ""
        prompt_info "Creating deployment group: $dg_name"

        if cd_deployment_group_exists "$CD_APPLICATION_NAME" "$dg_name" "$AWS_REGION"; then
            prompt_warning "Deployment group already exists: $dg_name"
        else
            local create_result=0

            if [ "$CD_COMPUTE_PLATFORM" = "Server" ]; then
                if [ "$CD_TARGET_TYPE" = "tags" ]; then
                    aws deploy create-deployment-group \
                        --application-name "$CD_APPLICATION_NAME" \
                        --deployment-group-name "$dg_name" \
                        --deployment-config-name "$CD_DEPLOYMENT_CONFIG" \
                        --service-role-arn "$service_role_arn" \
                        --ec2-tag-filters "[${CD_TARGET_VALUE}]" \
                        --tags Key=Project,Value=$PROJECT_NAME Key=Environment,Value=$env \
                        --region "$AWS_REGION" \
                        &>/dev/null
                    create_result=$?
                elif [ "$CD_TARGET_TYPE" = "asg" ]; then
                    # Use appropriate ASG based on environment
                    local target_asg="$CD_TARGET_VALUE"
                    if [ "${CREATE_NEW_ASGS:-no}" = "yes" ] || [ "${USE_SEPARATE_ASGS:-no}" = "yes" ]; then
                        if [ "$env" = "production" ]; then
                            target_asg="$ASG_PROD_NAME"
                        else
                            target_asg="$ASG_NONPROD_NAME"
                        fi
                    fi

                    aws deploy create-deployment-group \
                        --application-name "$CD_APPLICATION_NAME" \
                        --deployment-group-name "$dg_name" \
                        --deployment-config-name "$CD_DEPLOYMENT_CONFIG" \
                        --service-role-arn "$service_role_arn" \
                        --auto-scaling-groups "$target_asg" \
                        --tags Key=Project,Value=$PROJECT_NAME Key=Environment,Value=$env \
                        --region "$AWS_REGION" \
                        &>/dev/null
                    create_result=$?
                fi
            else
                # Lambda/ECS
                aws deploy create-deployment-group \
                    --application-name "$CD_APPLICATION_NAME" \
                    --deployment-group-name "$dg_name" \
                    --deployment-config-name "$CD_DEPLOYMENT_CONFIG" \
                    --service-role-arn "$service_role_arn" \
                    --tags Key=Project,Value=$PROJECT_NAME Key=Environment,Value=$env \
                    --region "$AWS_REGION" \
                    &>/dev/null
                create_result=$?
            fi

            if [ $create_result -eq 0 ]; then
                prompt_success "Deployment group created: $dg_name"
            else
                prompt_error "Failed to create deployment group: $dg_name"
                exit 1
            fi
        fi
    done

    # Save CodeDeploy configuration
    echo ""
    prompt_info "Saving project configuration..."
    if save_cd_config; then
        prompt_success "Configuration saved to ${PROJECT_ROOT}/${CD_CONFIG_DIR}/${CD_CONFIG_FILE}"
    else
        prompt_error "Failed to save configuration"
        exit 1
    fi

    # Generate appspec.yml
    echo ""
    prompt_info "Generating appspec.yml..."
    if generate_default_appspec "$PROJECT_TYPE" "${PROJECT_ROOT}/${CD_APPSPEC_LOCATION}"; then
        prompt_success "Created ${PROJECT_ROOT}/${CD_APPSPEC_LOCATION}"
    else
        prompt_warning "Could not create appspec.yml (may already exist)"
    fi

    # Generate lifecycle scripts if they don't exist
    echo ""
    if [ -d "${PROJECT_ROOT}/scripts" ]; then
        prompt_success "Found existing scripts/ directory"
        if prompt_confirm CREATE_SCRIPTS "Lifecycle scripts already exist. Regenerate them?" "no"; then
            generate_lifecycle_scripts "$PROJECT_TYPE" "${PROJECT_ROOT}" "$PROJECT_NAME" "$AWS_REGION"
            prompt_success "Lifecycle scripts regenerated in scripts/ directory"
            prompt_info "Please review and customize the scripts for your deployment needs"
        fi
    else
        if prompt_confirm CREATE_SCRIPTS "Create deployment lifecycle scripts (before_install.sh, start_server.sh, etc.)?" "yes"; then
            generate_lifecycle_scripts "$PROJECT_TYPE" "${PROJECT_ROOT}" "$PROJECT_NAME" "$AWS_REGION"
            prompt_success "Lifecycle scripts created in scripts/ directory"
            prompt_info "Please review and customize the scripts for your deployment needs"
            prompt_info ".env file will be created during build and included in artifact"
        fi
    fi

    fi  # End of SKIP_CODEDEPLOY_CONFIG check for PHASE 1

    # PHASE 2: Create Pipeline resources (if requested)
    if [ "$SETUP_PIPELINE" = "yes" ]; then
        echo ""
        prompt_header "Phase 2: CodePipeline Setup" "Creating CI/CD pipeline"
        echo ""

        # Store environment variables in SSM for all three environments
        if [ ${#BUILD_ENV_DEFAULTS[@]} -gt 0 ]; then
            prompt_info "Storing build environment variables in SSM for all environments..."

            for env in "production" "staging" "development"; do
                local env_count=0

                # First, store all defaults (unless overridden)
                for key in "${!BUILD_ENV_DEFAULTS[@]}"; do
                    local value="${BUILD_ENV_DEFAULTS[$key]}"

                    # Check for environment-specific override
                    case "$env" in
                        "production")
                            [ -n "${BUILD_ENV_PRODUCTION[$key]}" ] && value="${BUILD_ENV_PRODUCTION[$key]}"
                            ;;
                        "staging")
                            [ -n "${BUILD_ENV_STAGING[$key]}" ] && value="${BUILD_ENV_STAGING[$key]}"
                            ;;
                        "development")
                            [ -n "${BUILD_ENV_DEVELOPMENT[$key]}" ] && value="${BUILD_ENV_DEVELOPMENT[$key]}"
                            ;;
                    esac

                    param_name="/${PROJECT_NAME}/${env}/build/${key}"
                    aws ssm put-parameter \
                        --name "$param_name" \
                        --value "$value" \
                        --type "SecureString" \
                        --region "$AWS_REGION" \
                        --overwrite \
                        >/dev/null 2>&1
                    ((++env_count))
                done

                # Then, store any environment-specific variables that don't have defaults
                case "$env" in
                    "production")
                        for key in "${!BUILD_ENV_PRODUCTION[@]}"; do
                            [ -n "${BUILD_ENV_DEFAULTS[$key]}" ] && continue  # Skip if already stored
                            param_name="/${PROJECT_NAME}/${env}/build/${key}"
                            aws ssm put-parameter \
                                --name "$param_name" \
                                --value "${BUILD_ENV_PRODUCTION[$key]}" \
                                --type "SecureString" \
                                --region "$AWS_REGION" \
                                --overwrite \
                                >/dev/null 2>&1
                            ((++env_count))
                        done
                        ;;
                    "staging")
                        for key in "${!BUILD_ENV_STAGING[@]}"; do
                            [ -n "${BUILD_ENV_DEFAULTS[$key]}" ] && continue
                            param_name="/${PROJECT_NAME}/${env}/build/${key}"
                            aws ssm put-parameter \
                                --name "$param_name" \
                                --value "${BUILD_ENV_STAGING[$key]}" \
                                --type "SecureString" \
                                --region "$AWS_REGION" \
                                --overwrite \
                                >/dev/null 2>&1
                            ((++env_count))
                        done
                        ;;
                    "development")
                        for key in "${!BUILD_ENV_DEVELOPMENT[@]}"; do
                            [ -n "${BUILD_ENV_DEFAULTS[$key]}" ] && continue
                            param_name="/${PROJECT_NAME}/${env}/build/${key}"
                            aws ssm put-parameter \
                                --name "$param_name" \
                                --value "${BUILD_ENV_DEVELOPMENT[$key]}" \
                                --type "SecureString" \
                                --region "$AWS_REGION" \
                                --overwrite \
                                >/dev/null 2>&1
                            ((++env_count))
                        done
                        ;;
                esac

                echo -e "  ${CD_DIM}${env}: ${env_count} build variables${CD_RESET}"
            done
            prompt_success "Build variables stored in SSM for all environments"
        fi

        if [ ${#RUNTIME_ENV_DEFAULTS[@]} -gt 0 ]; then
            echo ""
            prompt_info "Storing runtime environment variables in SSM for all environments..."

            for env in "production" "staging" "development"; do
                local env_count=0

                # First, store all defaults (unless overridden)
                for key in "${!RUNTIME_ENV_DEFAULTS[@]}"; do
                    local value="${RUNTIME_ENV_DEFAULTS[$key]}"

                    # Check for environment-specific override
                    case "$env" in
                        "production")
                            [ -n "${RUNTIME_ENV_PRODUCTION[$key]}" ] && value="${RUNTIME_ENV_PRODUCTION[$key]}"
                            ;;
                        "staging")
                            [ -n "${RUNTIME_ENV_STAGING[$key]}" ] && value="${RUNTIME_ENV_STAGING[$key]}"
                            ;;
                        "development")
                            [ -n "${RUNTIME_ENV_DEVELOPMENT[$key]}" ] && value="${RUNTIME_ENV_DEVELOPMENT[$key]}"
                            ;;
                    esac

                    param_name="/${PROJECT_NAME}/${env}/${key}"
                    aws ssm put-parameter \
                        --name "$param_name" \
                        --value "$value" \
                        --type "SecureString" \
                        --region "$AWS_REGION" \
                        --overwrite \
                        >/dev/null 2>&1
                    ((++env_count))
                done

                # Then, store any environment-specific variables that don't have defaults
                case "$env" in
                    "production")
                        for key in "${!RUNTIME_ENV_PRODUCTION[@]}"; do
                            [ -n "${RUNTIME_ENV_DEFAULTS[$key]}" ] && continue  # Skip if already stored
                            param_name="/${PROJECT_NAME}/${env}/${key}"
                            aws ssm put-parameter \
                                --name "$param_name" \
                                --value "${RUNTIME_ENV_PRODUCTION[$key]}" \
                                --type "SecureString" \
                                --region "$AWS_REGION" \
                                --overwrite \
                                >/dev/null 2>&1
                            ((++env_count))
                        done
                        ;;
                    "staging")
                        for key in "${!RUNTIME_ENV_STAGING[@]}"; do
                            [ -n "${RUNTIME_ENV_DEFAULTS[$key]}" ] && continue
                            param_name="/${PROJECT_NAME}/${env}/${key}"
                            aws ssm put-parameter \
                                --name "$param_name" \
                                --value "${RUNTIME_ENV_STAGING[$key]}" \
                                --type "SecureString" \
                                --region "$AWS_REGION" \
                                --overwrite \
                                >/dev/null 2>&1
                            ((++env_count))
                        done
                        ;;
                    "development")
                        for key in "${!RUNTIME_ENV_DEVELOPMENT[@]}"; do
                            [ -n "${RUNTIME_ENV_DEFAULTS[$key]}" ] && continue
                            param_name="/${PROJECT_NAME}/${env}/${key}"
                            aws ssm put-parameter \
                                --name "$param_name" \
                                --value "${RUNTIME_ENV_DEVELOPMENT[$key]}" \
                                --type "SecureString" \
                                --region "$AWS_REGION" \
                                --overwrite \
                                >/dev/null 2>&1
                            ((++env_count))
                        done
                        ;;
                esac

                echo -e "  ${CD_DIM}${env}: ${env_count} runtime variables${CD_RESET}"
            done
            prompt_success "Runtime variables stored in SSM for all environments"
        fi

        # Create shared IAM roles for the project (used by all branches)
        echo ""
        prompt_info "Creating shared CodeBuild IAM role for project..."
        BUILD_ROLE_NAME="${PROJECT_NAME}-codebuild-role"
        BUILD_ROLE_ARN=$(create_codebuild_service_role "$BUILD_ROLE_NAME" "$AWS_REGION" "$PROJECT_NAME")
        if [ -n "$BUILD_ROLE_ARN" ]; then
            prompt_success "CodeBuild role created (shared by all branches)"
        else
            prompt_error "Failed to create CodeBuild role"
            exit 1
        fi

        echo ""
        prompt_info "Creating shared CodePipeline IAM role for project..."
        PIPELINE_ROLE_NAME="${PROJECT_NAME}-codepipeline-role"
        PIPELINE_ROLE_ARN=$(create_codepipeline_service_role "$PIPELINE_ROLE_NAME" "$AWS_REGION" "$PROJECT_NAME")
        if [ -n "$PIPELINE_ROLE_ARN" ]; then
            prompt_success "CodePipeline role created (shared by all branches)"
        else
            prompt_error "Failed to create CodePipeline role"
            exit 1
        fi

        # Loop through each selected branch and create pipeline + build project
        for BRANCH in "${BRANCHES[@]}"; do
            echo ""
            prompt_header "Setting up pipeline for branch: $BRANCH" "$(get_environment_from_branch "$BRANCH") environment"

            # Determine resource names for this branch
            BRANCH_BUILD_PROJECT_NAME="${PROJECT_NAME}-${BRANCH}-build"
            BRANCH_PIPELINE_NAME="${PROJECT_NAME}-${BRANCH}-pipeline"
            BRANCH_ENVIRONMENT=$(get_environment_from_branch "$BRANCH")
            BRANCH_DEPLOYMENT_GROUP="${PROJECT_NAME}-dg-${BRANCH_ENVIRONMENT}"

            # Create CodeBuild project for this branch (using shared role)
            echo ""
            prompt_info "Creating CodeBuild project: $BRANCH_BUILD_PROJECT_NAME..."
            BRANCH_BUILD_PROJECT=$(create_codebuild_project \
                "$BRANCH_BUILD_PROJECT_NAME" \
                "$BUILD_ROLE_ARN" \
                "buildspec.yml" \
                "$BUILD_COMPUTE_TYPE" \
                "$BUILD_IMAGE" \
                "$AWS_REGION" \
                "$PROJECT_NAME")

            if [ -n "$BRANCH_BUILD_PROJECT" ]; then
                prompt_success "CodeBuild project created"
            else
                prompt_error "Failed to create CodeBuild project"
                exit 1
            fi

            # Create CodePipeline for this branch (using shared role)
            echo ""
            prompt_info "Creating CodePipeline: $BRANCH_PIPELINE_NAME..."
            # Construct source configuration JSON
            local SOURCE_CONFIG_JSON=$(cat <<EOF
{
  "type": "$SOURCE_TYPE",
  "repo": "$REPO_ID",
  "branch": "$BRANCH",
  "connection_arn": "$CODESTAR_CONNECTION_ARN"
}
EOF
)

            BRANCH_PIPELINE=$(create_pipeline \
                "$BRANCH_PIPELINE_NAME" \
                "$PIPELINE_ROLE_ARN" \
                "$CD_S3_BUCKET" \
                "$SOURCE_CONFIG_JSON" \
                "$BRANCH_BUILD_PROJECT_NAME" \
                "$CD_APPLICATION_NAME" \
                "$BRANCH_DEPLOYMENT_GROUP" \
                "$AWS_REGION" \
                "$PROJECT_NAME")

            if [ -n "$BRANCH_PIPELINE" ]; then
                prompt_success "CodePipeline created for branch: $BRANCH"
            else
                prompt_error "Failed to create CodePipeline"
                exit 1
            fi
        done

        # Offer to add more branches
        echo ""
        ADD_MORE_BRANCHES="no"
        if prompt_confirm ADD_MORE_BRANCHES "Do you want to add pipelines for additional branches?" "yes"; then
            ADD_MORE_BRANCHES="yes"
        fi

        while [ "$ADD_MORE_BRANCHES" = "yes" ]; do
            echo ""
            prompt_header "Add Branch Pipeline" "Set up pipeline for another branch"
            echo ""

            # Get available branches (filter out already configured ones)
            local configured_branches=("${BRANCHES[@]}")
            local available_branches=()

            for branch in "main" "staging" "develop"; do
                local already_configured=false
                for configured in "${configured_branches[@]}"; do
                    if [ "$branch" = "$configured" ]; then
                        already_configured=true
                        break
                    fi
                done

                if [ "$already_configured" = false ]; then
                    available_branches+=("$branch")
                fi
            done

            if [ ${#available_branches[@]} -eq 0 ]; then
                prompt_info "All standard branches (main, staging, develop) already have pipelines"
                break
            fi

            echo -e "${CD_DIM}Available branches:${CD_RESET}"
            for branch in "${available_branches[@]}"; do
                local env=$(get_environment_from_branch "$branch")
                echo -e "  ${CD_GREEN}•${CD_RESET} ${CD_BOLD}$branch${CD_RESET} → ${env} environment"
            done
            echo ""

            available_branches+=("Cancel")

            local NEW_BRANCH
            if ! prompt_select NEW_BRANCH \
                "Select branch to add pipeline" \
                0 \
                "${available_branches[@]}"; then
                prompt_error "Failed to read input. Exiting."
                exit 1
            fi

            if [ "$NEW_BRANCH" = "Cancel" ]; then
                prompt_info "Skipping additional branches"
                break
            fi

            # Add to branches array
            BRANCHES+=("$NEW_BRANCH")

            # Create pipeline for the new branch
            BRANCH_BUILD_PROJECT_NAME="${PROJECT_NAME}-${NEW_BRANCH}-build"
            BRANCH_PIPELINE_NAME="${PROJECT_NAME}-${NEW_BRANCH}-pipeline"
            BRANCH_ENVIRONMENT=$(get_environment_from_branch "$NEW_BRANCH")
            BRANCH_DEPLOYMENT_GROUP="${PROJECT_NAME}-dg-${BRANCH_ENVIRONMENT}"

            echo ""
            prompt_header "Setting up pipeline for branch: $NEW_BRANCH" "$(get_environment_from_branch "$NEW_BRANCH") environment"

            # Create CodeBuild project
            echo ""
            prompt_info "Creating CodeBuild project: $BRANCH_BUILD_PROJECT_NAME..."
            BRANCH_BUILD_PROJECT=$(create_codebuild_project \
                "$BRANCH_BUILD_PROJECT_NAME" \
                "$BUILD_ROLE_ARN" \
                "buildspec.yml" \
                "$BUILD_COMPUTE_TYPE" \
                "$BUILD_IMAGE" \
                "$AWS_REGION" \
                "$PROJECT_NAME" \
                "$NEW_BRANCH")

            if [ -n "$BRANCH_BUILD_PROJECT" ]; then
                prompt_success "CodeBuild project created"
            else
                prompt_error "Failed to create CodeBuild project"
                exit 1
            fi

            # Create CodePipeline
            echo ""
            prompt_info "Creating CodePipeline: $BRANCH_PIPELINE_NAME..."
            local SOURCE_CONFIG_JSON=$(cat <<EOF
{
  "type": "$SOURCE_TYPE",
  "repo": "$REPO_ID",
  "branch": "$NEW_BRANCH",
  "connection_arn": "$CODESTAR_CONNECTION_ARN"
}
EOF
)

            BRANCH_PIPELINE=$(create_pipeline \
                "$BRANCH_PIPELINE_NAME" \
                "$PIPELINE_ROLE_ARN" \
                "$CD_S3_BUCKET" \
                "$SOURCE_CONFIG_JSON" \
                "$BRANCH_BUILD_PROJECT_NAME" \
                "$CD_APPLICATION_NAME" \
                "$BRANCH_DEPLOYMENT_GROUP" \
                "$AWS_REGION" \
                "$PROJECT_NAME")

            if [ -n "$BRANCH_PIPELINE" ]; then
                prompt_success "CodePipeline created for branch: $NEW_BRANCH"
            else
                prompt_error "Failed to create CodePipeline"
                exit 1
            fi

            # Ask if they want to add another
            echo ""
            ADD_MORE_BRANCHES="no"
            if [ ${#available_branches[@]} -gt 1 ]; then  # More than just "Cancel"
                if prompt_confirm ADD_MORE_BRANCHES "Do you want to add another branch pipeline?" "no"; then
                    ADD_MORE_BRANCHES="yes"
                fi
            else
                prompt_info "All standard branches now have pipelines"
            fi
        done

        # Generate buildspec.yml
        echo ""
        prompt_info "Generating buildspec.yml with branch-based environment detection..."

        # Generate buildspec with correct parameters
        # Note: buildspec now auto-detects environment from branch
        generate_buildspec_template \
            "$PROJECT_TYPE" \
            "$CODEBUILD_BUILD_COMMAND" \
            "$PROJECT_NAME" \
            "" \
            "" \
            "${PROJECT_ROOT}/buildspec.yml"

        if [ -f "${PROJECT_ROOT}/buildspec.yml" ]; then
            prompt_success "Created ${PROJECT_ROOT}/buildspec.yml"
            echo -e "${CD_DIM}  Buildspec includes automatic branch→environment detection${CD_RESET}"
            echo -e "${CD_DIM}  main → production, staging → staging, develop → development${CD_RESET}"
        else
            prompt_warning "Could not create buildspec.yml"
        fi
    fi

    # ============================================================================
    # COMPLETION
    # ============================================================================

    echo ""
    echo ""
    prompt_header "Setup Complete!" "Your AWS infrastructure is ready"

    print_box_header "Next Steps"
    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_BOLD}CodeDeploy is configured!${CD_RESET}"
    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  Configuration saved to:"
    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}    ${CD_GREEN}${PROJECT_ROOT}/${CD_CONFIG_DIR}/${CD_CONFIG_FILE}${CD_RESET}"
    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"

    if [ "$SETUP_PIPELINE" = "yes" ]; then
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_BOLD}CI/CD Pipeline is configured!${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  1. Review and commit the generated files:"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}     ${CD_DIM}git add buildspec.yml appspec.yml scripts/${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}     ${CD_DIM}git commit -m \"Add CI/CD configuration\"${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}     ${CD_DIM}git push${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  2. Pipeline will automatically trigger on push to ${CD_BOLD}$BRANCH_NAME${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  3. Monitor pipeline: https://console.aws.amazon.com/codesuite/codepipeline/pipelines"
    else
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  1. Review generated files:"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}     • ${CD_GREEN}appspec.yml${CD_RESET} - Deployment specification"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}     • ${CD_GREEN}scripts/${CD_RESET} - Lifecycle hook scripts"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  2. Set up CI/CD pipeline (optional):"
        echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}     ${CD_DIM}Run this script again to add CodePipeline${CD_RESET}"
    fi

    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}"
    echo -e "${CD_BOLD}${CD_CYAN}║${CD_RESET}  ${CD_YELLOW}View status:${CD_RESET} ${CD_GREEN}aws-code-info.sh${CD_RESET}"
    print_box_footer

    echo ""
    prompt_success "Setup completed successfully!"
    echo ""
}

# Run main or quick mode
if [ "${QUICK_PIPELINE_MODE:-false}" = "true" ]; then
    quick_add_pipelines
else
    main
fi
