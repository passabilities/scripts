#!/bin/bash

# AWS Infrastructure Visualization Script
# Maps resource relationships and displays architecture diagram

set -e

# Get script directory (resolve symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$( cd -P "$( dirname "$SOURCE" )" &> /dev/null && pwd )"
LIB_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"/src/lib

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
MAGENTA='\033[35m'
GRAY='\033[90m'
NC='\033[0m'

# Resource data structures (associative arrays)
declare -A RESOURCES
declare -A RELATIONSHIPS

# Function to add resource
add_resource() {
    local type=$1
    local id=$2
    local name=$3
    local status=$4

    RESOURCES["${type}:${id}"]="${name}|${status}"
}

# Function to add relationship
add_relationship() {
    local from_type=$1
    local from_id=$2
    local to_type=$3
    local to_id=$4
    local relationship=$5

    local key="${from_type}:${from_id}→${to_type}:${to_id}"
    RELATIONSHIPS["$key"]="$relationship"
}

# Function to discover all resources and their relationships
discover_all_resources() {
    local vpc_ids=""

    # Discover VPC(s)
    if is_filtering_by_project; then
        local vpc_name="${PROJECT_NAME}-vpc"
        vpc_ids=$(aws ec2 describe-vpcs \
            --region "$AWS_REGION" \
            --filters "Name=tag:Name,Values=$vpc_name" \
            --query 'Vpcs[*].VpcId' \
            --output text 2>/dev/null || echo "")
    else
        # Discover ALL VPCs
        vpc_ids=$(aws ec2 describe-vpcs \
            --region "$AWS_REGION" \
            --query 'Vpcs[*].VpcId' \
            --output text 2>/dev/null || echo "")
    fi

    for vpc_id in $vpc_ids; do
        [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ] && continue

        # Get VPC details
        local vpc_info=$(aws ec2 describe-vpcs \
            --region "$AWS_REGION" \
            --vpc-ids "$vpc_id" \
            --query 'Vpcs[0].[CidrBlock,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null)

        local vpc_cidr=$(echo "$vpc_info" | awk '{print $1}')
        local vpc_name=$(echo "$vpc_info" | awk '{print $2}')
        [ -z "$vpc_name" ] && vpc_name="$vpc_id"

        add_resource "VPC" "$vpc_id" "$vpc_name ($vpc_cidr)" "available"

        # Discover Subnets
        local subnets=$(aws ec2 describe-subnets \
            --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query 'Subnets[*].[SubnetId,CidrBlock,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null)

        while IFS=$'\t' read -r subnet_id cidr az name; do
            add_resource "Subnet" "$subnet_id" "$name ($cidr, $az)" "available"
            add_relationship "Subnet" "$subnet_id" "VPC" "$vpc_id" "belongs to"
        done <<< "$subnets"

        # Discover Internet Gateway
        local igw_id=$(aws ec2 describe-internet-gateways \
            --region "$AWS_REGION" \
            --filters "Name=attachment.vpc-id,Values=$vpc_id" \
            --query 'InternetGateways[0].InternetGatewayId' \
            --output text 2>/dev/null)

        if [ -n "$igw_id" ] && [ "$igw_id" != "None" ]; then
            add_resource "IGW" "$igw_id" "Internet Gateway" "attached"
            add_relationship "IGW" "$igw_id" "VPC" "$vpc_id" "attached to"
        fi

        # Discover NAT Gateways
        local nat_gateways=$(aws ec2 describe-nat-gateways \
            --region "$AWS_REGION" \
            --filter "Name=vpc-id,Values=$vpc_id" \
            --query 'NatGateways[*].[NatGatewayId,State,SubnetId]' \
            --output text 2>/dev/null)

        while IFS=$'\t' read -r nat_id state subnet_id; do
            add_resource "NAT" "$nat_id" "NAT Gateway" "$state"
            add_relationship "NAT" "$nat_id" "Subnet" "$subnet_id" "deployed in"
            add_relationship "NAT" "$nat_id" "VPC" "$vpc_id" "provides NAT for"
        done <<< "$nat_gateways"

        # Discover Security Groups
        local sgs=""
        if is_filtering_by_project; then
            sgs=$(aws ec2 describe-security-groups \
                --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Project,Values=$PROJECT_NAME" \
                --query 'SecurityGroups[*].[GroupId,GroupName,Description]' \
                --output text 2>/dev/null)
        else
            sgs=$(aws ec2 describe-security-groups \
                --region "$AWS_REGION" \
                --filters "Name=vpc-id,Values=$vpc_id" \
                --query 'SecurityGroups[*].[GroupId,GroupName,Description]' \
                --output text 2>/dev/null)
        fi

        while IFS=$'\t' read -r sg_id sg_name description; do
            [ -z "$sg_id" ] && continue
            add_resource "SG" "$sg_id" "$sg_name" "active"
            add_relationship "SG" "$sg_id" "VPC" "$vpc_id" "controls traffic in"
        done <<< "$sgs"
    done

    # Discover RDS instances (outside VPC loop as RDS may not be in discovered VPCs)
    if is_filtering_by_project; then
        local db_identifier="${PROJECT_NAME}-db"
        local db_info=$(aws rds describe-db-instances \
            --region "$AWS_REGION" \
            --db-instance-identifier "$db_identifier" \
            --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,VpcId,VpcSecurityGroups[0].VpcSecurityGroupId,DBSubnetGroup.Subnets[*].SubnetIdentifier]' \
            --output text 2>/dev/null || echo "")

        if [ -n "$db_info" ]; then
            local db_vpc_id db_sg_id subnet_ids
            IFS=$'\t' read -r db_id status db_vpc_id db_sg_id subnet_ids <<< "$db_info"

            add_resource "RDS" "$db_id" "PostgreSQL Database" "$status"
            [ -n "$db_vpc_id" ] && add_relationship "RDS" "$db_id" "VPC" "$db_vpc_id" "deployed in"
            [ -n "$db_sg_id" ] && add_relationship "RDS" "$db_id" "SG" "$db_sg_id" "protected by"

            for subnet_id in $subnet_ids; do
                [ -n "$subnet_id" ] && add_relationship "RDS" "$db_id" "Subnet" "$subnet_id" "uses"
            done
        fi
    else
        # Discover ALL RDS instances
        local all_db_instances=$(aws rds describe-db-instances \
            --region "$AWS_REGION" \
            --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus,DBInstanceClass,VpcId,VpcSecurityGroups[0].VpcSecurityGroupId,DBSubnetGroup.Subnets[*].SubnetIdentifier]' \
            --output text 2>/dev/null)

        while IFS=$'\t' read -r db_id status db_class db_vpc_id db_sg_id subnet_ids; do
            [ -z "$db_id" ] && continue
            add_resource "RDS" "$db_id" "$db_class Database" "$status"
            [ -n "$db_vpc_id" ] && add_relationship "RDS" "$db_id" "VPC" "$db_vpc_id" "deployed in"
            [ -n "$db_sg_id" ] && add_relationship "RDS" "$db_id" "SG" "$db_sg_id" "protected by"

            for subnet_id in $subnet_ids; do
                [ -n "$subnet_id" ] && add_relationship "RDS" "$db_id" "Subnet" "$subnet_id" "uses"
            done
        done <<< "$all_db_instances"
    fi

    # Discover ElastiCache clusters
    if is_filtering_by_project; then
        local cache_id="${PROJECT_NAME}-redis"
        local cache_info=$(aws elasticache describe-replication-groups \
            --region "$AWS_REGION" \
            --replication-group-id "$cache_id" \
            --query 'ReplicationGroups[0].[ReplicationGroupId,Status]' \
            --output text 2>/dev/null || echo "")

        if [ -n "$cache_info" ]; then
            IFS=$'\t' read -r repl_id status <<< "$cache_info"

            add_resource "Cache" "$repl_id" "Redis Cluster" "$status"

            # Get cache security groups and VPC info
            local cache_sgs=$(aws elasticache describe-cache-clusters \
                --region "$AWS_REGION" \
                --query "CacheClusters[?ReplicationGroupId=='${cache_id}'].SecurityGroups[*].SecurityGroupId" \
                --output text 2>/dev/null)

            for sg_id in $cache_sgs; do
                [ -n "$sg_id" ] && add_relationship "Cache" "$repl_id" "SG" "$sg_id" "protected by"
            done
        fi
    else
        # Discover ALL ElastiCache clusters
        local all_cache_clusters=$(aws elasticache describe-replication-groups \
            --region "$AWS_REGION" \
            --query 'ReplicationGroups[*].[ReplicationGroupId,Status,CacheNodeType]' \
            --output text 2>/dev/null)

        while IFS=$'\t' read -r repl_id status node_type; do
            [ -z "$repl_id" ] && continue
            add_resource "Cache" "$repl_id" "$node_type Cluster" "$status"
        done <<< "$all_cache_clusters"
    fi

    # Discover Elastic Beanstalk applications
    if is_filtering_by_project; then
        local app_name="${PROJECT_NAME}-app-${ENVIRONMENT}"
        local app_exists=$(aws elasticbeanstalk describe-applications \
            --region "$AWS_REGION" \
            --application-names "$app_name" \
            --query 'Applications[0].ApplicationName' \
            --output text 2>/dev/null || echo "")

        if [ -n "$app_exists" ] && [ "$app_exists" != "None" ]; then
            add_resource "EB-App" "$app_name" "EB Application" "active"

            # Get environments
            local environments=$(aws elasticbeanstalk describe-environments \
                --region "$AWS_REGION" \
                --application-name "$app_name" \
                --query 'Environments[*].[EnvironmentName,Status,Health]' \
                --output text 2>/dev/null)

            while IFS=$'\t' read -r env_name status health; do
                [ -z "$env_name" ] && continue
                add_resource "EB-Env" "$env_name" "$env_name" "$status"
                add_relationship "EB-Env" "$env_name" "EB-App" "$app_name" "belongs to"
            done <<< "$environments"
        fi
    else
        # Discover ALL EB applications
        local all_apps=$(aws elasticbeanstalk describe-applications \
            --region "$AWS_REGION" \
            --query 'Applications[*].ApplicationName' \
            --output text 2>/dev/null)

        for app_name in $all_apps; do
            [ -z "$app_name" ] && continue
            add_resource "EB-App" "$app_name" "EB Application" "active"

            local environments=$(aws elasticbeanstalk describe-environments \
                --region "$AWS_REGION" \
                --application-name "$app_name" \
                --query 'Environments[*].[EnvironmentName,Status]' \
                --output text 2>/dev/null)

            while IFS=$'\t' read -r env_name status; do
                [ -z "$env_name" ] && continue
                add_resource "EB-Env" "$env_name" "$env_name" "$status"
                add_relationship "EB-Env" "$env_name" "EB-App" "$app_name" "belongs to"
            done <<< "$environments"
        done
    fi

    # Discover S3 (independent of VPC)
    local buckets=""
    if is_filtering_by_project; then
        buckets=$(aws s3api list-buckets \
            --query "Buckets[?contains(Name, '${PROJECT_NAME}')].[Name]" \
            --output text 2>/dev/null || echo "")
    else
        buckets=$(aws s3api list-buckets \
            --query "Buckets[*].Name" \
            --output text 2>/dev/null || echo "")
    fi

    for bucket_name in $buckets; do
        [ -z "$bucket_name" ] && continue
        add_resource "S3" "$bucket_name" "$bucket_name" "active"
    done

    # Discover SES (independent of VPC)
    local identities=$(aws ses list-identities \
        --region "$AWS_REGION" \
        --query 'Identities' \
        --output text 2>/dev/null || echo "")

    for identity in $identities; do
        [ -z "$identity" ] && continue
        add_resource "SES" "$identity" "Email Service" "active"
    done
}

# Function to print dependency tree
print_dependency_tree() {
    echo -e "\n${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Resource Dependency Tree${NC}"
    echo -e "${BOLD}${CYAN}╠═══════════════════════════════════════════════════════════════════════════╣${NC}"

    # Group by resource type
    local printed_resources=()

    # Print VPC hierarchy
    for key in "${!RESOURCES[@]}"; do
        IFS=':' read -r type id <<< "$key"

        if [ "$type" = "VPC" ]; then
            IFS='|' read -r name status <<< "${RESOURCES[$key]}"
            echo -e "${BOLD}${CYAN}║${NC}"
            echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}▸ VPC${NC} ${BLUE}${name}${NC}"
            printed_resources+=("$key")

            # Print children of VPC
            print_children "VPC" "$id" "    "
        fi
    done

    # Print standalone resources (S3, SES)
    for key in "${!RESOURCES[@]}"; do
        IFS=':' read -r type id <<< "$key"

        if [[ ! " ${printed_resources[@]} " =~ " ${key} " ]]; then
            IFS='|' read -r name status <<< "${RESOURCES[$key]}"

            if [ "$type" = "S3" ] || [ "$type" = "SES" ]; then
                echo -e "${BOLD}${CYAN}║${NC}"
                echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}▸ ${type}${NC} ${BLUE}${name}${NC}"
                printed_resources+=("$key")
                print_children "$type" "$id" "    "
            fi
        fi
    done

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to print children of a resource
print_children() {
    local parent_type=$1
    local parent_id=$2
    local indent=$3

    for rel_key in "${!RELATIONSHIPS[@]}"; do
        # Parse relationship: from_type:from_id→to_type:to_id
        if [[ "$rel_key" =~ (.+):(.+)→(.+):(.+) ]]; then
            local from_type="${BASH_REMATCH[3]}"
            local from_id="${BASH_REMATCH[4]}"
            local to_type="${BASH_REMATCH[1]}"
            local to_id="${BASH_REMATCH[2]}"
            local relationship="${RELATIONSHIPS[$rel_key]}"

            if [ "$from_type" = "$parent_type" ] && [ "$from_id" = "$parent_id" ]; then
                local child_key="${to_type}:${to_id}"
                if [ -n "${RESOURCES[$child_key]}" ]; then
                    IFS='|' read -r name status <<< "${RESOURCES[$child_key]}"

                    echo -e "${BOLD}${CYAN}║${NC}  ${indent}${GRAY}│${NC}"
                    echo -e "${BOLD}${CYAN}║${NC}  ${indent}${GRAY}├─${NC} ${YELLOW}${to_type}${NC} ${BLUE}${name}${NC} ${DIM}(${relationship})${NC}"

                    # Recursively print grandchildren
                    print_children "$to_type" "$to_id" "${indent}│  "
                fi
            fi
        fi
    done
}

# Function to print architecture diagram
print_architecture_diagram() {
    echo -e "\n${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Architecture Diagram${NC}"
    echo -e "${BOLD}${CYAN}╠═══════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}"

    # Check what resources exist
    local has_vpc=false
    local has_rds=false
    local has_cache=false
    local has_eb=false
    local has_s3=false
    local has_ses=false

    for key in "${!RESOURCES[@]}"; do
        IFS=':' read -r type id <<< "$key"
        case "$type" in
            VPC) has_vpc=true ;;
            RDS) has_rds=true ;;
            Cache) has_cache=true ;;
            EB-Env) has_eb=true ;;
            S3) has_s3=true ;;
            SES) has_ses=true ;;
        esac
    done

    # Draw diagram
    echo -e "${BOLD}${CYAN}║${NC}                    ${GRAY}┌────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                    ${GRAY}│${NC}  ${BLUE}Internet${NC}         ${GRAY}│${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                    ${GRAY}└──────────┬─────────┘${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                               ${GRAY}│${NC}"

    if [ "$has_vpc" = true ]; then
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${BOLD}VPC${NC} ${DIM}(${PROJECT_NAME}-vpc)${NC}                       ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}                   ${GRAY}│${NC}                              ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}            ${YELLOW}┌──────▼──────┐${NC}                       ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}            ${YELLOW}│${NC} ${BOLD}Internet GW${NC} ${YELLOW}│${NC}                       ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}            ${YELLOW}└──────┬──────┘${NC}                       ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}                   ${GRAY}│${NC}                              ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}┌────────────────┴────────────────┐${NC}           ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${BOLD}Public Subnets${NC}              ${GRAY}│${NC}           ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}┌──────────┐${NC}  ${MAGENTA}┌──────────┐${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"

        if [ "$has_eb" = true ]; then
            echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}│${NC} ${BOLD}EB Env${NC}   ${MAGENTA}│${NC}  ${MAGENTA}│${NC} NAT GW   ${MAGENTA}│${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"
        else
            echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}│${NC}          ${MAGENTA}│${NC}  ${MAGENTA}│${NC} NAT GW   ${MAGENTA}│${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"
        fi

        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}└──────────┘${NC}  ${MAGENTA}└─────┬────┘${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}└────────────────┬──────────┼────────┘${NC}           ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}                   ${GRAY}│${NC}          ${GRAY}│${NC}                    ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}┌────────────────┴──────────▼────────┐${NC}           ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${BOLD}Private Subnets${NC}             ${GRAY}│${NC}           ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}┌──────────┐${NC}  ${MAGENTA}┌──────────┐${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"

        if [ "$has_rds" = true ] && [ "$has_cache" = true ]; then
            echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}│${NC} ${BOLD}RDS${NC}      ${MAGENTA}│${NC}  ${MAGENTA}│${NC} ${BOLD}Redis${NC}    ${MAGENTA}│${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"
        elif [ "$has_rds" = true ]; then
            echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}│${NC} ${BOLD}RDS${NC}      ${MAGENTA}│${NC}  ${MAGENTA}│${NC}          ${MAGENTA}│${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"
        elif [ "$has_cache" = true ]; then
            echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}│${NC}          ${MAGENTA}│${NC}  ${MAGENTA}│${NC} ${BOLD}Redis${NC}    ${MAGENTA}│${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"
        else
            echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}│${NC}          ${MAGENTA}│${NC}  ${MAGENTA}│${NC}          ${MAGENTA}│${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"
        fi

        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}│${NC}  ${MAGENTA}└──────────┘${NC}  ${MAGENTA}└──────────┘${NC}   ${GRAY}│${NC}           ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}║${NC}  ${GRAY}└─────────────────────────────────────┘${NC}           ${GREEN}║${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    fi

    # External services
    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}     ${BOLD}External Services:${NC}"

    if [ "$has_s3" = true ]; then
        echo -e "${BOLD}${CYAN}║${NC}     ${BLUE}┌─────────────┐${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${BLUE}│${NC}  ${BOLD}S3 Storage${NC} ${BLUE}│${NC}  ${DIM}(artifact storage)${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${BLUE}└─────────────┘${NC}"
    fi

    if [ "$has_ses" = true ]; then
        echo -e "${BOLD}${CYAN}║${NC}     ${BLUE}┌─────────────┐${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${BLUE}│${NC}  ${BOLD}SES Email${NC}  ${BLUE}│${NC}  ${DIM}(email service)${NC}"
        echo -e "${BOLD}${CYAN}║${NC}     ${BLUE}└─────────────┘${NC}"
    fi

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to print relationship matrix
print_relationship_matrix() {
    echo -e "\n${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Resource Relationships${NC}"
    echo -e "${BOLD}${CYAN}╠═══════════════════════════════════════════════════════════════════════════╣${NC}"

    if [ ${#RELATIONSHIPS[@]} -eq 0 ]; then
        echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}No relationships discovered${NC}"
    else
        for key in "${!RELATIONSHIPS[@]}"; do
            # Parse relationship: from_type:from_id→to_type:to_id
            if [[ "$key" =~ (.+):(.+)→(.+):(.+) ]]; then
                local from_type="${BASH_REMATCH[1]}"
                local from_id="${BASH_REMATCH[2]}"
                local to_type="${BASH_REMATCH[3]}"
                local to_id="${BASH_REMATCH[4]}"
                local relationship="${RELATIONSHIPS[$key]}"

                local from_key="${from_type}:${from_id}"
                local to_key="${to_type}:${to_id}"

                if [ -n "${RESOURCES[$from_key]}" ] && [ -n "${RESOURCES[$to_key]}" ]; then
                    IFS='|' read -r from_name from_status <<< "${RESOURCES[$from_key]}"
                    IFS='|' read -r to_name to_status <<< "${RESOURCES[$to_key]}"

                    echo -e "${BOLD}${CYAN}║${NC}"
                    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}${from_type}${NC} ${BLUE}${from_name}${NC}"
                    echo -e "${BOLD}${CYAN}║${NC}    ${GRAY}↓${NC} ${DIM}${relationship}${NC}"
                    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}${to_type}${NC} ${BLUE}${to_name}${NC}"
                fi
            fi
        done
    fi

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Main execution
main() {
    clear

    # Display header
    echo -e "${BOLD}${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║                   AWS Infrastructure Visualization                        ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Show configuration
    echo -e "${DIM}Analyzing infrastructure for:${NC}"
    echo -e "  ${CYAN}Project:${NC} ${GREEN}${PROJECT_NAME}${NC}"
    echo -e "  ${CYAN}Environment:${NC} ${GREEN}${ENVIRONMENT}${NC}"
    echo -e "  ${CYAN}Region:${NC} ${GREEN}${AWS_REGION}${NC}"

    echo ""
    echo -e "${YELLOW}⏳${NC} ${DIM}Discovering resources and mapping relationships...${NC}"

    # Discover all resources
    discover_all_resources

    # Display visualizations
    print_architecture_diagram
    print_dependency_tree
    print_relationship_matrix

    # Summary
    echo ""
    echo -e "${GREEN}✓${NC} ${BOLD}Visualization complete!${NC}"
    echo -e "${DIM}Found ${#RESOURCES[@]} resources with ${#RELATIONSHIPS[@]} relationships${NC}"
    echo ""
}

# Run main
main
