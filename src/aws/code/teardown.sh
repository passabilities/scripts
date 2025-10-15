#!/bin/bash

# AWS CodeDeploy + CodePipeline Teardown Script
# Safely deletes all resources created by the setup script

# Get the directory where this script is actually located (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
    SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

# LIB_DIR is at src/lib (script is at src/aws/code, so go up two levels then to lib)
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/lib"

# Source required libraries
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/codedeploy"
source "${LIB_DIR}/codepipeline"

# Determine if we're running from within a project
PROJECT_ROOT="$(pwd)"
CONFIG_LOADED=false

if load_cd_config; then
    CONFIG_LOADED=true
    PROJECT_ROOT="$CD_PROJECT_ROOT"
else
    echo ""
    prompt_error "No CodeDeploy configuration found in current directory"
    prompt_info "Please run this script from your project root directory"
    exit 1
fi

# Main teardown function
main() {
    clear
    echo -e "${CD_BOLD}${CD_CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║              AWS Infrastructure Teardown - DANGER ZONE                   ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${CD_RESET}"
    echo ""

    prompt_warning "This will DELETE AWS resources for project: ${CD_BOLD}${PROJECT_NAME}${CD_RESET}"
    echo ""

    # Scan for existing resources
    echo ""
    prompt_header "Scanning for Resources" "Finding all resources to delete"
    echo ""

    # Find pipelines
    prompt_info "Checking for CodePipeline pipelines..."
    local pipelines=$(aws codepipeline list-pipelines \
        --region "$AWS_REGION" \
        --query "pipelines[?starts_with(name, '${PROJECT_NAME}-')].name" \
        --output text 2>/dev/null || echo "")

    local pipeline_count=0
    if [ -n "$pipelines" ]; then
        for pipeline in $pipelines; do
            echo -e "  ${CD_RED}✗${CD_RESET} $pipeline"
            ((pipeline_count++))
        done
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
    fi

    # Find build projects
    echo ""
    prompt_info "Checking for CodeBuild projects..."
    local build_projects=$(aws codebuild list-projects \
        --region "$AWS_REGION" \
        --query "projects[?starts_with(@, '${PROJECT_NAME}-')]" \
        --output text 2>/dev/null || echo "")

    local build_count=0
    if [ -n "$build_projects" ]; then
        for project in $build_projects; do
            echo -e "  ${CD_RED}✗${CD_RESET} $project"
            ((build_count++))
        done
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
    fi

    # Find deployment groups
    echo ""
    prompt_info "Checking for CodeDeploy deployment groups..."
    local deployment_groups=$(aws deploy list-deployment-groups \
        --application-name "$CD_APPLICATION_NAME" \
        --region "$AWS_REGION" \
        --query 'deploymentGroups[]' \
        --output text 2>/dev/null || echo "")

    local dg_count=0
    if [ -n "$deployment_groups" ]; then
        for dg in $deployment_groups; do
            echo -e "  ${CD_RED}✗${CD_RESET} $dg"
            ((dg_count++))
        done
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
    fi

    # Check for CodeDeploy application
    echo ""
    prompt_info "Checking for CodeDeploy application..."
    local app_exists=$(aws deploy get-application \
        --application-name "$CD_APPLICATION_NAME" \
        --region "$AWS_REGION" \
        --query 'application.applicationName' \
        --output text 2>/dev/null)

    if [ -n "$app_exists" ] && [ "$app_exists" != "None" ]; then
        echo -e "  ${CD_RED}✗${CD_RESET} $CD_APPLICATION_NAME"
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
        app_exists=""
    fi

    # Find Auto Scaling Groups
    echo ""
    prompt_info "Checking for Auto Scaling Groups..."
    local asgs=$(aws autoscaling describe-auto-scaling-groups \
        --region "$AWS_REGION" \
        --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '${PROJECT_NAME}-')].AutoScalingGroupName" \
        --output text 2>/dev/null || echo "")

    local asg_count=0
    if [ -n "$asgs" ]; then
        for asg in $asgs; do
            echo -e "  ${CD_RED}✗${CD_RESET} $asg"
            ((asg_count++))
        done
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
    fi

    # Find Load Balancers
    echo ""
    prompt_info "Checking for Load Balancers..."
    local albs=$(aws elbv2 describe-load-balancers \
        --region "$AWS_REGION" \
        --query "LoadBalancers[?starts_with(LoadBalancerName, '${PROJECT_NAME}-')].LoadBalancerArn" \
        --output text 2>/dev/null || echo "")

    local alb_count=0
    if [ -n "$albs" ]; then
        for alb in $albs; do
            local alb_name=$(aws elbv2 describe-load-balancers \
                --load-balancer-arns "$alb" \
                --region "$AWS_REGION" \
                --query 'LoadBalancers[0].LoadBalancerName' \
                --output text 2>/dev/null)
            echo -e "  ${CD_RED}✗${CD_RESET} $alb_name"
            ((alb_count++))
        done
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
    fi

    # Find Target Groups
    echo ""
    prompt_info "Checking for Target Groups..."
    local target_groups=$(aws elbv2 describe-target-groups \
        --region "$AWS_REGION" \
        --query "TargetGroups[?starts_with(TargetGroupName, '${PROJECT_NAME}-')].TargetGroupArn" \
        --output text 2>/dev/null || echo "")

    local tg_count=0
    if [ -n "$target_groups" ]; then
        for tg in $target_groups; do
            local tg_name=$(aws elbv2 describe-target-groups \
                --target-group-arns "$tg" \
                --region "$AWS_REGION" \
                --query 'TargetGroups[0].TargetGroupName' \
                --output text 2>/dev/null)
            echo -e "  ${CD_RED}✗${CD_RESET} $tg_name"
            ((tg_count++))
        done
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
    fi

    # Find Launch Templates
    echo ""
    prompt_info "Checking for Launch Templates..."
    local templates=$(aws ec2 describe-launch-templates \
        --region "$AWS_REGION" \
        --query "LaunchTemplates[?starts_with(LaunchTemplateName, '${PROJECT_NAME}-')].LaunchTemplateId" \
        --output text 2>/dev/null || echo "")

    local template_count=0
    if [ -n "$templates" ]; then
        for template in $templates; do
            local template_name=$(aws ec2 describe-launch-templates \
                --launch-template-ids "$template" \
                --region "$AWS_REGION" \
                --query 'LaunchTemplates[0].LaunchTemplateName' \
                --output text 2>/dev/null)
            echo -e "  ${CD_RED}✗${CD_RESET} $template_name"
            ((template_count++))
        done
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
    fi

    # Find IAM Roles
    echo ""
    prompt_info "Checking for IAM Roles..."
    local roles=("${PROJECT_NAME}-codedeploy-role" "${PROJECT_NAME}-codebuild-role" "${PROJECT_NAME}-codepipeline-role")
    local role_count=0
    for role in "${roles[@]}"; do
        local role_exists=$(aws iam get-role \
            --role-name "$role" \
            --query 'Role.RoleName' \
            --output text 2>/dev/null)
        if [ -n "$role_exists" ] && [ "$role_exists" != "None" ]; then
            echo -e "  ${CD_RED}✗${CD_RESET} $role"
            ((role_count++))
        fi
    done
    if [ $role_count -eq 0 ]; then
        echo -e "  ${CD_DIM}None found${CD_RESET}"
    fi

    # Check for S3 bucket
    echo ""
    prompt_info "Checking for S3 bucket..."
    if aws s3 ls "s3://${CD_S3_BUCKET}" &>/dev/null; then
        echo -e "  ${CD_YELLOW}⚠${CD_RESET}  ${CD_S3_BUCKET} ${CD_DIM}(optional)${CD_RESET}"
        local s3_exists=true
    else
        echo -e "  ${CD_DIM}None found${CD_RESET}"
        local s3_exists=false
    fi

    # Summary
    echo ""
    echo ""
    prompt_header "Deletion Summary" "Resources to be deleted"
    echo ""
    echo -e "  CodePipeline Pipelines:     ${CD_RED}${pipeline_count}${CD_RESET}"
    echo -e "  CodeBuild Projects:         ${CD_RED}${build_count}${CD_RESET}"
    echo -e "  CodeDeploy Groups:          ${CD_RED}${dg_count}${CD_RESET}"
    echo -e "  CodeDeploy Application:     ${CD_RED}$([ -n "$app_exists" ] && echo "1" || echo "0")${CD_RESET}"
    echo -e "  Auto Scaling Groups:        ${CD_RED}${asg_count}${CD_RESET}"
    echo -e "  Load Balancers:             ${CD_RED}${alb_count}${CD_RESET}"
    echo -e "  Target Groups:              ${CD_RED}${tg_count}${CD_RESET}"
    echo -e "  Launch Templates:           ${CD_RED}${template_count}${CD_RESET}"
    echo -e "  IAM Roles:                  ${CD_RED}${role_count}${CD_RESET}"
    echo -e "  S3 Bucket:                  ${CD_YELLOW}$([ "$s3_exists" = true ] && echo "optional" || echo "0")${CD_RESET}"
    echo ""

    # Confirm deletion
    echo ""
    prompt_warning "This action CANNOT be undone!"
    echo ""

    prompt_confirm CONFIRM_DELETE "Are you sure you want to delete these resources?" "no"

    if [ "$CONFIRM_DELETE" != "yes" ]; then
        prompt_info "Teardown cancelled"
        exit 0
    fi

    # Double confirm for safety
    echo ""
    echo -e "${CD_BOLD}${CD_RED}FINAL CONFIRMATION - THIS CANNOT BE UNDONE!${CD_RESET}"
    echo ""
    echo -e "${CD_YELLOW}Type the word ${CD_BOLD}DELETE${CD_RESET}${CD_YELLOW} (in capitals) to confirm:${CD_RESET}"
    read -r CONFIRMATION

    if [ "$CONFIRMATION" != "DELETE" ]; then
        prompt_info "Teardown cancelled (did not type DELETE)"
        exit 0
    fi

    # Start deletion
    echo ""
    echo ""
    prompt_header "Deleting Resources" "This may take several minutes"
    echo ""

    # Delete CodePipelines
    if [ $pipeline_count -gt 0 ]; then
        prompt_info "Deleting CodePipeline pipelines..."
        for pipeline in $pipelines; do
            aws codepipeline delete-pipeline \
                --name "$pipeline" \
                --region "$AWS_REGION" \
                &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $pipeline"
            else
                echo -e "  ${CD_RED}✗${CD_RESET} Failed: $pipeline"
            fi
        done
        echo ""
    fi

    # Delete CodeBuild projects
    if [ $build_count -gt 0 ]; then
        prompt_info "Deleting CodeBuild projects..."
        for project in $build_projects; do
            aws codebuild delete-project \
                --name "$project" \
                --region "$AWS_REGION" \
                &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $project"
            else
                echo -e "  ${CD_RED}✗${CD_RESET} Failed: $project"
            fi
        done
        echo ""
    fi

    # Delete Deployment Groups
    if [ $dg_count -gt 0 ]; then
        prompt_info "Deleting CodeDeploy deployment groups..."
        for dg in $deployment_groups; do
            aws deploy delete-deployment-group \
                --application-name "$CD_APPLICATION_NAME" \
                --deployment-group-name "$dg" \
                --region "$AWS_REGION" \
                &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $dg"
            else
                echo -e "  ${CD_RED}✗${CD_RESET} Failed: $dg"
            fi
        done
        echo ""
    fi

    # Delete CodeDeploy Application
    if [ -n "$app_exists" ]; then
        prompt_info "Deleting CodeDeploy application..."
        aws deploy delete-application \
            --application-name "$CD_APPLICATION_NAME" \
            --region "$AWS_REGION" \
            &>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $CD_APPLICATION_NAME"
        else
            echo -e "  ${CD_RED}✗${CD_RESET} Failed: $CD_APPLICATION_NAME"
        fi
        echo ""
    fi

    # Delete Auto Scaling Groups
    if [ $asg_count -gt 0 ]; then
        prompt_info "Deleting Auto Scaling Groups..."
        for asg in $asgs; do
            # Set desired capacity to 0 first
            aws autoscaling update-auto-scaling-group \
                --auto-scaling-group-name "$asg" \
                --min-size 0 \
                --desired-capacity 0 \
                --region "$AWS_REGION" \
                &>/dev/null

            # Force delete ASG
            aws autoscaling delete-auto-scaling-group \
                --auto-scaling-group-name "$asg" \
                --force-delete \
                --region "$AWS_REGION" \
                &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $asg"
            else
                echo -e "  ${CD_RED}✗${CD_RESET} Failed: $asg"
            fi
        done
        echo ""
        prompt_info "Waiting for ASG instances to terminate (30 seconds)..."
        sleep 30
        echo ""
    fi

    # Delete Load Balancers
    if [ $alb_count -gt 0 ]; then
        prompt_info "Deleting Load Balancers..."
        for alb in $albs; do
            local alb_name=$(aws elbv2 describe-load-balancers \
                --load-balancer-arns "$alb" \
                --region "$AWS_REGION" \
                --query 'LoadBalancers[0].LoadBalancerName' \
                --output text 2>/dev/null)

            aws elbv2 delete-load-balancer \
                --load-balancer-arn "$alb" \
                --region "$AWS_REGION" \
                &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $alb_name"
            else
                echo -e "  ${CD_RED}✗${CD_RESET} Failed: $alb_name"
            fi
        done
        echo ""
        prompt_info "Waiting for Load Balancers to be fully deleted (30 seconds)..."
        sleep 30
        echo ""
    fi

    # Delete Target Groups
    if [ $tg_count -gt 0 ]; then
        prompt_info "Deleting Target Groups..."
        for tg in $target_groups; do
            local tg_name=$(aws elbv2 describe-target-groups \
                --target-group-arns "$tg" \
                --region "$AWS_REGION" \
                --query 'TargetGroups[0].TargetGroupName' \
                --output text 2>/dev/null)

            aws elbv2 delete-target-group \
                --target-group-arn "$tg" \
                --region "$AWS_REGION" \
                &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $tg_name"
            else
                echo -e "  ${CD_RED}✗${CD_RESET} Failed: $tg_name"
            fi
        done
        echo ""
    fi

    # Delete Launch Templates
    if [ $template_count -gt 0 ]; then
        prompt_info "Deleting Launch Templates..."
        for template in $templates; do
            local template_name=$(aws ec2 describe-launch-templates \
                --launch-template-ids "$template" \
                --region "$AWS_REGION" \
                --query 'LaunchTemplates[0].LaunchTemplateName' \
                --output text 2>/dev/null)

            aws ec2 delete-launch-template \
                --launch-template-id "$template" \
                --region "$AWS_REGION" \
                &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $template_name"
            else
                echo -e "  ${CD_RED}✗${CD_RESET} Failed: $template_name"
            fi
        done
        echo ""
    fi

    # Delete IAM Roles
    if [ $role_count -gt 0 ]; then
        prompt_info "Deleting IAM Roles..."
        for role in "${roles[@]}"; do
            local role_exists=$(aws iam get-role \
                --role-name "$role" \
                --query 'Role.RoleName' \
                --output text 2>/dev/null)

            if [ -n "$role_exists" ] && [ "$role_exists" != "None" ]; then
                # Delete inline policies first
                local policies=$(aws iam list-role-policies \
                    --role-name "$role" \
                    --query 'PolicyNames[]' \
                    --output text 2>/dev/null)

                for policy in $policies; do
                    aws iam delete-role-policy \
                        --role-name "$role" \
                        --policy-name "$policy" \
                        &>/dev/null
                done

                # Detach managed policies
                local managed_policies=$(aws iam list-attached-role-policies \
                    --role-name "$role" \
                    --query 'AttachedPolicies[].PolicyArn' \
                    --output text 2>/dev/null)

                for policy_arn in $managed_policies; do
                    aws iam detach-role-policy \
                        --role-name "$role" \
                        --policy-arn "$policy_arn" \
                        &>/dev/null
                done

                # Delete instance profile if it exists
                if [[ "$role" == *"codedeploy"* ]]; then
                    local instance_profile="${CD_APPLICATION_NAME}-instance-profile"
                    aws iam remove-role-from-instance-profile \
                        --instance-profile-name "$instance_profile" \
                        --role-name "$role" \
                        &>/dev/null
                    aws iam delete-instance-profile \
                        --instance-profile-name "$instance_profile" \
                        &>/dev/null
                fi

                # Delete role
                aws iam delete-role \
                    --role-name "$role" \
                    &>/dev/null
                if [ $? -eq 0 ]; then
                    echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $role"
                else
                    echo -e "  ${CD_RED}✗${CD_RESET} Failed: $role"
                fi
            fi
        done
        echo ""
    fi

    # Delete S3 bucket (optional)
    if [ "$s3_exists" = true ]; then
        echo ""
        prompt_confirm DELETE_S3 "Delete S3 bucket ${CD_S3_BUCKET}? (contains deployment artifacts)" "no"

        if [ "$DELETE_S3" = "yes" ]; then
            prompt_info "Emptying and deleting S3 bucket..."
            # Empty bucket first
            aws s3 rm "s3://${CD_S3_BUCKET}" --recursive --region "$AWS_REGION" &>/dev/null
            # Delete bucket
            aws s3 rb "s3://${CD_S3_BUCKET}" --region "$AWS_REGION" &>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: $CD_S3_BUCKET"
            else
                echo -e "  ${CD_RED}✗${CD_RESET} Failed: $CD_S3_BUCKET"
            fi
        else
            echo -e "  ${CD_YELLOW}⚠${CD_RESET}  Skipped: $CD_S3_BUCKET"
        fi
        echo ""
    fi

    # Delete local configuration
    echo ""
    prompt_confirm DELETE_CONFIG "Delete local project configuration (.codedeploy/)?" "yes"

    if [ "$DELETE_CONFIG" = "yes" ]; then
        prompt_info "Deleting local configuration..."
        rm -rf "${PROJECT_ROOT}/.codedeploy"
        echo -e "  ${CD_GREEN}✓${CD_RESET} Deleted: .codedeploy/"
    else
        echo -e "  ${CD_YELLOW}⚠${CD_RESET}  Kept: .codedeploy/"
    fi

    # Complete
    echo ""
    echo ""
    prompt_success "Teardown complete!"
    echo ""
    prompt_info "All selected resources have been deleted"
    echo ""
}

# Run main
main
