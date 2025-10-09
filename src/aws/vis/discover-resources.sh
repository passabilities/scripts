#!/bin/bash

# AWS Resource Discovery Script
# Discovers all AWS resources for a project and displays them in an organized format

set -e

# Get script directory (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/src/lib"

# Source libraries
source "${LIB_DIR}/prompts"
source "${LIB_DIR}/config-display"
source "${LIB_DIR}/config-prompt"

# Prompt for configuration (allow "show all" option)
prompt_aws_config "true" "visualization"

# Display active configuration
display_config_summary

# Colors
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
RED='\033[31m'
GRAY='\033[90m'
NC='\033[0m'

# Icons
ICON_VPC="🌐"
ICON_DB="🗄️"
ICON_CACHE="⚡"
ICON_STORAGE="📦"
ICON_EMAIL="📧"
ICON_APP="🚀"
ICON_NETWORK="🔗"
ICON_SECURITY="🔒"

# Function to print section header
print_section() {
    local title=$1
    local icon=$2
    echo -e "\n${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${icon}  ${BOLD}${title}${NC}"
    echo -e "${BOLD}${CYAN}╠═══════════════════════════════════════════════════════════════════════════╣${NC}"
}

# Function to print resource separator (between multiple resources of same type)
print_resource_separator() {
    echo -e "${BOLD}${CYAN}║${NC}  ${DIM}${GRAY}─────────────────────────────────────────────────────────────────────────${NC}"
}

# Function to print resource item
print_resource() {
    local label=$1
    local value=$2
    local status=$3
    local name=$4  # Optional custom name/label

    local status_icon=""
    local status_color="${GREEN}"

    case "$status" in
        "available"|"active"|"running"|"healthy")
            status_icon="✓"
            status_color="${GREEN}"
            ;;
        "pending"|"creating"|"updating")
            status_icon="⏳"
            status_color="${YELLOW}"
            ;;
        "deleted"|"failed"|"unhealthy")
            status_icon="✗"
            status_color="${RED}"
            ;;
        *)
            status_icon="•"
            status_color="${BLUE}"
            ;;
    esac

    echo -e "${BOLD}${CYAN}║${NC}  ${DIM}${label}:${NC}"
    echo -e "${BOLD}${CYAN}║${NC}    ${status_color}${status_icon}${NC} ${GREEN}${value}${NC}"

    # Show custom name if provided
    if [ -n "$name" ] && [ "$name" != "None" ]; then
        echo -e "${BOLD}${CYAN}║${NC}      ${DIM}Name: ${BOLD}${name}${NC}"
    fi

    if [ -n "$status" ]; then
        echo -e "${BOLD}${CYAN}║${NC}      ${DIM}Status: ${status_color}${status}${NC}"
    fi
}

# Function to close section
close_section() {
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to discover VPC resources
discover_vpc() {
    print_section "VPC & Network Resources" "$ICON_VPC"

    local found_vpcs=false
    local vpc_ids=""

    if is_filtering_by_project; then
        # Find specific VPC by project name
        local vpc_name="$(get_project_name)-vpc"
        vpc_ids=$(aws ec2 describe-vpcs \
            --region "$AWS_REGION" \
            --filters "Name=tag:Name,Values=$vpc_name" \
            --query 'Vpcs[*].VpcId' \
            --output text 2>/dev/null || echo "")
    else
        # Show ALL VPCs
        vpc_ids=$(aws ec2 describe-vpcs \
            --region "$AWS_REGION" \
            --query 'Vpcs[*].VpcId' \
            --output text 2>/dev/null || echo "")
    fi

    if [ -n "$vpc_ids" ]; then
        local first_vpc=true
        for vpc_id in $vpc_ids; do
            [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ] && continue
            found_vpcs=true

            # Add separator between VPCs (except before first one)
            if [ "$first_vpc" = false ]; then
                print_resource_separator
            fi
            first_vpc=false

        local vpc_info=$(aws ec2 describe-vpcs \
            --region "$AWS_REGION" \
            --vpc-ids "$vpc_id" \
            --query 'Vpcs[0].[CidrBlock,State,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null)

        IFS=$'\t' read -r vpc_cidr vpc_state vpc_name <<< "$vpc_info"

        print_resource "VPC" "$vpc_id ($vpc_cidr)" "$vpc_state" "$vpc_name"

        # Get subnets
        local subnets=$(aws ec2 describe-subnets \
            --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null)

        if [ -n "$subnets" ]; then
            echo -e "${BOLD}${CYAN}║${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Subnets:${NC}"
            while IFS=$'\t' read -r subnet_id cidr az name; do
                echo -e "${BOLD}${CYAN}║${NC}    ${BLUE}•${NC} ${GREEN}${subnet_id}${NC} ${DIM}(${cidr}, ${az})${NC}"
                echo -e "${BOLD}${CYAN}║${NC}      ${DIM}${name}${NC}"
            done <<< "$subnets"
        fi

        # Get Internet Gateway
        local igw_id=$(aws ec2 describe-internet-gateways \
            --region "$AWS_REGION" \
            --filters "Name=attachment.vpc-id,Values=$vpc_id" \
            --query 'InternetGateways[0].InternetGatewayId' \
            --output text 2>/dev/null)

        if [ -n "$igw_id" ] && [ "$igw_id" != "None" ]; then
            echo -e "${BOLD}${CYAN}║${NC}"
            print_resource "Internet Gateway" "$igw_id" "attached"
        fi

        # Get NAT Gateways
        local nat_gateways=$(aws ec2 describe-nat-gateways \
            --region "$AWS_REGION" \
            --filter "Name=vpc-id,Values=$vpc_id" \
            --query 'NatGateways[*].[NatGatewayId,State,SubnetId]' \
            --output text 2>/dev/null)

        if [ -n "$nat_gateways" ]; then
            echo -e "${BOLD}${CYAN}║${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}NAT Gateways:${NC}"
            while IFS=$'\t' read -r nat_id state subnet_id; do
                local status_color="${GREEN}"
                [ "$state" != "available" ] && status_color="${YELLOW}"
                echo -e "${BOLD}${CYAN}║${NC}    ${status_color}•${NC} ${GREEN}${nat_id}${NC} ${DIM}(${state})${NC}"
            done <<< "$nat_gateways"
        fi

            echo -e "${BOLD}${CYAN}║${NC}"
        done
    fi

    if [ "$found_vpcs" = false ]; then
        if is_filtering_by_project; then
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No VPC found for project: ${PROJECT_NAME}${NC}"
        else
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No VPCs found in region: ${AWS_REGION}${NC}"
        fi
    fi

    close_section
}

# Function to discover RDS resources
discover_rds() {
    print_section "RDS Database Resources" "$ICON_DB"

    local found_instances=false

    local first_db=true
    if is_filtering_by_project; then
        # Query specific instance by project name
        local db_identifier="${PROJECT_NAME}-db"
        local db_info=$(aws rds describe-db-instances \
            --region "$AWS_REGION" \
            --db-instance-identifier "$db_identifier" \
            --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Engine,EngineVersion,DBInstanceClass,Endpoint.Address,Endpoint.Port,AllocatedStorage,DBName]' \
            --output text 2>/dev/null || echo "")

        if [ -n "$db_info" ]; then
            found_instances=true
            IFS=$'\t' read -r db_id status engine version instance_class endpoint port storage db_name <<< "$db_info"

            print_resource "Database Instance" "$db_id" "$status" "$db_name"
            echo -e "${BOLD}${CYAN}║${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Engine:${NC} ${GREEN}${engine} ${version}${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Instance Class:${NC} ${GREEN}${instance_class}${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Storage:${NC} ${GREEN}${storage} GB${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Endpoint:${NC} ${GREEN}${endpoint}:${port}${NC}"
        fi
    else
        # Show ALL RDS instances
        local all_instances=$(aws rds describe-db-instances \
            --region "$AWS_REGION" \
            --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus,Engine,EngineVersion,DBInstanceClass,Endpoint.Address,Endpoint.Port,AllocatedStorage,DBName]' \
            --output text 2>/dev/null)

        if [ -n "$all_instances" ]; then
            found_instances=true
            while IFS=$'\t' read -r db_id status engine version instance_class endpoint port storage db_name; do
                [ -z "$db_id" ] && continue

                # Add separator between databases (except before first one)
                if [ "$first_db" = false ]; then
                    print_resource_separator
                fi
                first_db=false

                print_resource "Database Instance" "$db_id" "$status" "$db_name"
                echo -e "${BOLD}${CYAN}║${NC}"
                echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Engine:${NC} ${GREEN}${engine} ${version}${NC}"
                echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Instance Class:${NC} ${GREEN}${instance_class}${NC}"
                echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Storage:${NC} ${GREEN}${storage} GB${NC}"
                echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Endpoint:${NC} ${GREEN}${endpoint}:${port}${NC}"
                echo -e "${BOLD}${CYAN}║${NC}"
            done <<< "$all_instances"
        fi
    fi

    if [ "$found_instances" = false ]; then
        if is_filtering_by_project; then
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No RDS instance found for project: ${PROJECT_NAME}${NC}"
        else
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No RDS instances found in region: ${AWS_REGION}${NC}"
        fi
    fi

    close_section
}

# Function to discover ElastiCache resources
discover_elasticache() {
    print_section "ElastiCache (Redis) Resources" "$ICON_CACHE"

    local found_clusters=false
    local first_cache=true

    if is_filtering_by_project; then
        # Query specific cluster by project name
        local cache_id="${PROJECT_NAME}-redis"
        local cache_info=$(aws elasticache describe-replication-groups \
            --region "$AWS_REGION" \
            --replication-group-id "$cache_id" \
            --query 'ReplicationGroups[0].[ReplicationGroupId,Status,CacheNodeType,NodeGroups[0].PrimaryEndpoint.Address,NodeGroups[0].PrimaryEndpoint.Port,Description]' \
            --output text 2>/dev/null || echo "")

        if [ -n "$cache_info" ]; then
            found_clusters=true
            IFS=$'\t' read -r repl_id status node_type endpoint port description <<< "$cache_info"

            print_resource "Redis Cluster" "$repl_id" "$status" "$description"
            echo -e "${BOLD}${CYAN}║${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Node Type:${NC} ${GREEN}${node_type}${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Endpoint:${NC} ${GREEN}${endpoint}:${port}${NC}"
        fi
    else
        # Show ALL ElastiCache clusters
        local all_clusters=$(aws elasticache describe-replication-groups \
            --region "$AWS_REGION" \
            --query 'ReplicationGroups[*].[ReplicationGroupId,Status,CacheNodeType,NodeGroups[0].PrimaryEndpoint.Address,NodeGroups[0].PrimaryEndpoint.Port,Description]' \
            --output text 2>/dev/null)

        if [ -n "$all_clusters" ]; then
            found_clusters=true
            while IFS=$'\t' read -r repl_id status node_type endpoint port description; do
                [ -z "$repl_id" ] && continue

                # Add separator between clusters (except before first one)
                if [ "$first_cache" = false ]; then
                    print_resource_separator
                fi
                first_cache=false

                print_resource "Redis Cluster" "$repl_id" "$status" "$description"
                echo -e "${BOLD}${CYAN}║${NC}"
                echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Node Type:${NC} ${GREEN}${node_type}${NC}"
                echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Endpoint:${NC} ${GREEN}${endpoint}:${port}${NC}"
                echo -e "${BOLD}${CYAN}║${NC}"
            done <<< "$all_clusters"
        fi
    fi

    if [ "$found_clusters" = false ]; then
        if is_filtering_by_project; then
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No ElastiCache cluster found for project: ${PROJECT_NAME}${NC}"
        else
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No ElastiCache clusters found in region: ${AWS_REGION}${NC}"
        fi
    fi

    close_section
}

# Function to discover S3 resources
discover_s3() {
    print_section "S3 Storage Resources" "$ICON_STORAGE"

    local buckets=""

    if is_filtering_by_project; then
        # List buckets with project name
        buckets=$(aws s3api list-buckets \
            --query "Buckets[?contains(Name, '${PROJECT_NAME}')].[Name,CreationDate]" \
            --output text 2>/dev/null || echo "")
    else
        # List ALL buckets
        buckets=$(aws s3api list-buckets \
            --query "Buckets[*].[Name,CreationDate]" \
            --output text 2>/dev/null || echo "")
    fi

    if [ -n "$buckets" ]; then
        local first_bucket=true
        local found_in_region=false

        while IFS=$'\t' read -r bucket_name created; do
            [ -z "$bucket_name" ] && continue

            # Get bucket region
            local bucket_region=$(aws s3api get-bucket-location \
                --bucket "$bucket_name" \
                --query 'LocationConstraint' \
                --output text 2>/dev/null || echo "us-east-1")

            [ "$bucket_region" = "None" ] && bucket_region="us-east-1"

            # Skip buckets not in the selected region
            if [ "$bucket_region" != "$AWS_REGION" ]; then
                continue
            fi

            found_in_region=true

            # Add separator between buckets (except before first one)
            if [ "$first_bucket" = false ]; then
                print_resource_separator
            fi
            first_bucket=false

            # Get versioning status
            local versioning=$(aws s3api get-bucket-versioning \
                --bucket "$bucket_name" \
                --query 'Status' \
                --output text 2>/dev/null || echo "Disabled")

            [ "$versioning" = "None" ] && versioning="Disabled"

            # Try to get bucket tags for a custom name
            local bucket_label=$(aws s3api get-bucket-tagging \
                --bucket "$bucket_name" \
                --query "TagSet[?Key=='Name'].Value|[0]" \
                --output text 2>/dev/null || echo "")

            print_resource "S3 Bucket" "$bucket_name" "active" "$bucket_label"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Region:${NC} ${GREEN}${bucket_region}${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Versioning:${NC} ${GREEN}${versioning}${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Created:${NC} ${DIM}${created}${NC}"
            echo -e "${BOLD}${CYAN}║${NC}"
        done <<< "$buckets"

        if [ "$found_in_region" = false ]; then
            if is_filtering_by_project; then
                echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No S3 buckets found for project: ${PROJECT_NAME} in region: ${AWS_REGION}${NC}"
            else
                echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No S3 buckets found in region: ${AWS_REGION}${NC}"
            fi
        fi
    else
        if is_filtering_by_project; then
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No S3 buckets found for project: ${PROJECT_NAME}${NC}"
        else
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No S3 buckets found${NC}"
        fi
    fi

    close_section
}

# Function to discover SES resources
discover_ses() {
    print_section "SES Email Service Resources" "$ICON_EMAIL"

    # List verified identities
    local identities=$(aws ses list-identities \
        --region "$AWS_REGION" \
        --query 'Identities' \
        --output text 2>/dev/null || echo "")

    if [ -n "$identities" ]; then
        local first_identity=true
        for identity in $identities; do
            # Add separator between identities (except before first one)
            if [ "$first_identity" = false ]; then
                print_resource_separator
            fi
            first_identity=false

            # Get verification status
            local verification=$(aws ses get-identity-verification-attributes \
                --region "$AWS_REGION" \
                --identities "$identity" \
                --query "VerificationAttributes.\"${identity}\".VerificationStatus" \
                --output text 2>/dev/null || echo "Unknown")

            local status_color="${GREEN}"
            [ "$verification" != "Success" ] && status_color="${YELLOW}"

            print_resource "Email Identity" "$identity" "$verification"
            echo -e "${BOLD}${CYAN}║${NC}"
        done
    else
        echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No SES identities found${NC}"
    fi

    close_section
}

# Function to discover Elastic Beanstalk resources
discover_elasticbeanstalk() {
    print_section "Elastic Beanstalk Resources" "$ICON_APP"

    local found_apps=false
    local applications=""

    if is_filtering_by_project; then
        # Query specific application by project name
        local app_name="${PROJECT_NAME}-app-${ENVIRONMENT}"
        applications=$(aws elasticbeanstalk describe-applications \
            --region "$AWS_REGION" \
            --application-names "$app_name" \
            --query 'Applications[*].[ApplicationName,Description]' \
            --output text 2>/dev/null || echo "")
    else
        # Show ALL EB applications
        applications=$(aws elasticbeanstalk describe-applications \
            --region "$AWS_REGION" \
            --query 'Applications[*].[ApplicationName,Description]' \
            --output text 2>/dev/null || echo "")
    fi

    if [ -n "$applications" ]; then
        local first_app=true
        while IFS=$'\t' read -r app_name app_description; do
            [ -z "$app_name" ] || [ "$app_name" = "None" ] && continue
            found_apps=true

            # Add separator between applications (except before first one)
            if [ "$first_app" = false ]; then
                print_resource_separator
            fi
            first_app=false

            print_resource "Application" "$app_name" "active" "$app_description"

            # List environments for this application
            local environments=$(aws elasticbeanstalk describe-environments \
                --region "$AWS_REGION" \
                --application-name "$app_name" \
                --query 'Environments[*].[EnvironmentName,Status,Health,CNAME]' \
                --output text 2>/dev/null || echo "")

            if [ -n "$environments" ]; then
                echo -e "${BOLD}${CYAN}║${NC}"
                echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Environments:${NC}"
                local first_env=true
                while IFS=$'\t' read -r env_name status health cname; do
                    [ -z "$env_name" ] && continue

                    # Add mini separator between environments
                    if [ "$first_env" = false ]; then
                        echo -e "${BOLD}${CYAN}║${NC}      ${DIM}${GRAY}· · · · · ·${NC}"
                    fi
                    first_env=false

                    local status_color="${GREEN}"
                    [ "$status" != "Ready" ] && status_color="${YELLOW}"
                    [ "$health" = "Red" ] && status_color="${RED}"

                    echo -e "${BOLD}${CYAN}║${NC}    ${status_color}•${NC} ${GREEN}${env_name}${NC}"
                    echo -e "${BOLD}${CYAN}║${NC}      ${DIM}Status: ${status_color}${status}${NC}"
                    echo -e "${BOLD}${CYAN}║${NC}      ${DIM}Health: ${status_color}${health}${NC}"
                    echo -e "${BOLD}${CYAN}║${NC}      ${DIM}URL: ${CYAN}http://${cname}${NC}"
                done <<< "$environments"
            fi
            echo -e "${BOLD}${CYAN}║${NC}"
        done <<< "$applications"
    fi

    if [ "$found_apps" = false ]; then
        if is_filtering_by_project; then
            local expected_app="${PROJECT_NAME}-app-${ENVIRONMENT}"
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No Elastic Beanstalk application found for: ${expected_app}${NC}"
        else
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No Elastic Beanstalk applications found in region: ${AWS_REGION}${NC}"
        fi
    fi

    close_section
}

# Function to discover Security Groups
discover_security_groups() {
    print_section "Security Groups" "$ICON_SECURITY"

    local sgs=""
    if is_filtering_by_project; then
        # Find security groups for the project
        sgs=$(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --filters "Name=tag:Project,Values=$PROJECT_NAME" \
            --query 'SecurityGroups[*].[GroupId,GroupName,Description,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null || echo "")
    else
        # Show ALL security groups
        sgs=$(aws ec2 describe-security-groups \
            --region "$AWS_REGION" \
            --query 'SecurityGroups[*].[GroupId,GroupName,Description,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null || echo "")
    fi

    if [ -n "$sgs" ]; then
        local first_sg=true
        while IFS=$'\t' read -r sg_id sg_name description sg_label; do
            [ -z "$sg_id" ] && continue

            # Add separator between security groups (except before first one)
            if [ "$first_sg" = false ]; then
                print_resource_separator
            fi
            first_sg=false

            print_resource "Security Group" "$sg_name ($sg_id)" "active" "$sg_label"
            echo -e "${BOLD}${CYAN}║${NC}  ${DIM}Description: ${description}${NC}"
            echo -e "${BOLD}${CYAN}║${NC}"
        done <<< "$sgs"
    else
        if is_filtering_by_project; then
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No security groups found for project: ${PROJECT_NAME}${NC}"
        else
            echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}⚠${NC} ${DIM}No security groups found in region: ${AWS_REGION}${NC}"
        fi
    fi

    close_section
}

# Main execution
main() {
    clear

    # Display header
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║                      AWS Resource Discovery                               ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Show mode
    if is_filtering_by_project; then
        echo -e "${DIM}Discovering resources for project: ${GREEN}${PROJECT_NAME}${NC}"
    else
        echo -e "${DIM}Discovering ${YELLOW}ALL${NC}${DIM} resources in ${GREEN}${AWS_REGION}${NC}"
    fi

    # Discover all resources
    discover_vpc
    discover_rds
    discover_elasticache
    discover_s3
    discover_ses
    discover_elasticbeanstalk
    discover_security_groups

    # Summary
    echo ""
    echo -e "${GREEN}✓${NC} ${BOLD}Discovery complete!${NC}"
    echo ""
}

# Run main
main
