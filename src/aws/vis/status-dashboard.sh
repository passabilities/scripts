#!/bin/bash

# AWS Infrastructure Status Dashboard
# Real-time health monitoring and metrics for all resources

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

# Health status counters
HEALTHY=0
WARNING=0
CRITICAL=0
UNKNOWN=0

# Function to print status with health indicator
print_status() {
    local resource=$1
    local name=$2
    local status=$3
    local health=${4:-"unknown"}

    local health_icon=""
    local health_color="${GREEN}"

    case "$health" in
        "healthy"|"available"|"active"|"Ready"|"Green"|"Success")
            health_icon="●"
            health_color="${GREEN}"
            HEALTHY=$((HEALTHY + 1))
            ;;
        "warning"|"pending"|"Yellow"|"updating")
            health_icon="●"
            health_color="${YELLOW}"
            WARNING=$((WARNING + 1))
            ;;
        "critical"|"failed"|"Red"|"deleted"|"unavailable")
            health_icon="●"
            health_color="${RED}"
            CRITICAL=$((CRITICAL + 1))
            ;;
        *)
            health_icon="○"
            health_color="${GRAY}"
            UNKNOWN=$((UNKNOWN + 1))
            ;;
    esac

    printf "${BOLD}${CYAN}║${NC}  %-20s ${health_color}${health_icon}${NC} ${GREEN}%-30s${NC} ${DIM}%s${NC}\n" \
        "$resource" "$name" "$status"
}

# Function to check VPC health
check_vpc() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}VPC & Network${NC}"
    echo -e "${BOLD}${CYAN}╟───────────────────────────────────────────────────────────────────────────╢${NC}"

    local vpc_ids=""
    local found_any=false
    local first_vpc=true

    if is_filtering_by_project; then
        local vpc_name="${PROJECT_NAME}-vpc"
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

    for vpc_id in $vpc_ids; do
        [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ] && continue

        found_any=true

        # Add separator between VPCs (except before first one)
        if [ "$first_vpc" = false ]; then
            echo -e "${BOLD}${CYAN}║${NC}"
        fi
        first_vpc=false

        # Get VPC details including name
        local vpc_info=$(aws ec2 describe-vpcs \
            --region "$AWS_REGION" \
            --vpc-ids "$vpc_id" \
            --query 'Vpcs[0].[State,Tags[?Key==`Name`].Value|[0]]' \
            --output text 2>/dev/null)

        local state=$(echo "$vpc_info" | awk '{print $1}')
        local vpc_name=$(echo "$vpc_info" | awk '{print $2}')
        [ -z "$vpc_name" ] && vpc_name="$vpc_id"

        print_status "VPC" "$vpc_name" "$state" "$state"

        # Check NAT Gateway
        local nat_status=$(aws ec2 describe-nat-gateways \
            --region "$AWS_REGION" \
            --filter "Name=vpc-id,Values=$vpc_id" \
            --query 'NatGateways[0].State' \
            --output text 2>/dev/null || echo "")

        if [ -n "$nat_status" ] && [ "$nat_status" != "None" ]; then
            print_status "  NAT Gateway" "Primary" "$nat_status" "$nat_status"
        fi

        # Check IGW
        local igw_status=$(aws ec2 describe-internet-gateways \
            --region "$AWS_REGION" \
            --filters "Name=attachment.vpc-id,Values=$vpc_id" \
            --query 'InternetGateways[0].Attachments[0].State' \
            --output text 2>/dev/null || echo "")

        if [ -n "$igw_status" ] && [ "$igw_status" != "None" ]; then
            local health="healthy"
            [ "$igw_status" != "available" ] && health="warning"
            print_status "  Internet Gateway" "Main IGW" "$igw_status" "$health"
        fi
    done

    if [ "$found_any" = false ]; then
        if is_filtering_by_project; then
            print_status "VPC" "${PROJECT_NAME}-vpc" "Not Found" "critical"
        else
            print_status "VPC" "No VPCs found" "" "unknown"
        fi
    fi

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to check RDS health
check_rds() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Database (RDS)${NC}"
    echo -e "${BOLD}${CYAN}╟───────────────────────────────────────────────────────────────────────────╢${NC}"

    if is_filtering_by_project; then
        # Query specific instance by project name
        local db_identifier="${PROJECT_NAME}-db"
        local db_info=$(aws rds describe-db-instances \
            --region "$AWS_REGION" \
            --db-instance-identifier "$db_identifier" \
            --query 'DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,StorageEncrypted,MultiAZ]' \
            --output text 2>/dev/null || echo "")

        if [ -n "$db_info" ]; then
            IFS=$'\t' read -r db_id status encrypted multi_az <<< "$db_info"

            local health="healthy"
            [ "$status" != "available" ] && health="warning"
            [ "$status" = "failed" ] && health="critical"

            print_status "RDS Instance" "$db_id" "$status" "$health"

            # Storage encryption
            local enc_status="Disabled"
            local enc_health="warning"
            if [ "$encrypted" = "True" ]; then
                enc_status="Enabled"
                enc_health="healthy"
            fi
            print_status "  Encryption" "$enc_status" "" "$enc_health"

            # Multi-AZ
            local az_status="Single AZ"
            local az_health="warning"
            if [ "$multi_az" = "True" ]; then
                az_status="Multi-AZ"
                az_health="healthy"
            fi
            print_status "  High Availability" "$az_status" "" "$az_health"

            # Get CPU metrics
            local cpu_avg=$(aws cloudwatch get-metric-statistics \
                --region "$AWS_REGION" \
                --namespace AWS/RDS \
                --metric-name CPUUtilization \
                --dimensions Name=DBInstanceIdentifier,Value="$db_identifier" \
                --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
                --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
                --period 300 \
                --statistics Average \
                --query 'Datapoints[0].Average' \
                --output text 2>/dev/null || echo "N/A")

            if [ "$cpu_avg" != "N/A" ] && [ "$cpu_avg" != "None" ]; then
                local cpu_health="healthy"
                local cpu_int=$(printf "%.0f" "$cpu_avg" 2>/dev/null || echo "0")
                [ "$cpu_int" -gt 70 ] && cpu_health="warning"
                [ "$cpu_int" -gt 90 ] && cpu_health="critical"
                print_status "  CPU Usage" "${cpu_int}%" "Last 5 min avg" "$cpu_health"
            fi
        else
            print_status "RDS Instance" "$db_identifier" "Not Found" "critical"
        fi
    else
        # Show ALL RDS instances
        local all_instances=$(aws rds describe-db-instances \
            --region "$AWS_REGION" \
            --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus,StorageEncrypted,MultiAZ]' \
            --output text 2>/dev/null)

        local found_any=false
        local first_db=true
        while IFS=$'\t' read -r db_id status encrypted multi_az; do
            [ -z "$db_id" ] && continue

            found_any=true

            # Add separator between instances (except before first one)
            if [ "$first_db" = false ]; then
                echo -e "${BOLD}${CYAN}║${NC}"
            fi
            first_db=false

            local health="healthy"
            [ "$status" != "available" ] && health="warning"
            [ "$status" = "failed" ] && health="critical"

            print_status "RDS Instance" "$db_id" "$status" "$health"

            # Storage encryption
            local enc_status="Disabled"
            local enc_health="warning"
            if [ "$encrypted" = "True" ]; then
                enc_status="Enabled"
                enc_health="healthy"
            fi
            print_status "  Encryption" "$enc_status" "" "$enc_health"

            # Multi-AZ
            local az_status="Single AZ"
            local az_health="warning"
            if [ "$multi_az" = "True" ]; then
                az_status="Multi-AZ"
                az_health="healthy"
            fi
            print_status "  High Availability" "$az_status" "" "$az_health"
        done <<< "$all_instances"

        if [ "$found_any" = false ]; then
            print_status "RDS Instances" "None found" "" "unknown"
        fi
    fi

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to check ElastiCache health
check_elasticache() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Cache (ElastiCache)${NC}"
    echo -e "${BOLD}${CYAN}╟───────────────────────────────────────────────────────────────────────────╢${NC}"

    if is_filtering_by_project; then
        # Query specific cluster by project name
        local cache_id="${PROJECT_NAME}-redis"
        local cache_info=$(aws elasticache describe-replication-groups \
            --region "$AWS_REGION" \
            --replication-group-id "$cache_id" \
            --query 'ReplicationGroups[0].[ReplicationGroupId,Status,AtRestEncryptionEnabled,TransitEncryptionEnabled]' \
            --output text 2>/dev/null || echo "")

        if [ -n "$cache_info" ]; then
            IFS=$'\t' read -r repl_id status at_rest_enc transit_enc <<< "$cache_info"

            local health="healthy"
            [ "$status" != "available" ] && health="warning"

            print_status "Redis Cluster" "$repl_id" "$status" "$health"

            # Encryption at rest
            local enc_status="Disabled"
            local enc_health="warning"
            if [ "$at_rest_enc" = "True" ]; then
                enc_status="Enabled"
                enc_health="healthy"
            fi
            print_status "  Encryption at Rest" "$enc_status" "" "$enc_health"

            # Encryption in transit
            local transit_status="Disabled"
            local transit_health="warning"
            if [ "$transit_enc" = "True" ]; then
                transit_status="Enabled"
                transit_health="healthy"
            fi
            print_status "  Encryption in Transit" "$transit_status" "" "$transit_health"

            # Get cache hits/misses
            local cache_hits=$(aws cloudwatch get-metric-statistics \
                --region "$AWS_REGION" \
                --namespace AWS/ElastiCache \
                --metric-name CacheHits \
                --dimensions Name=ReplicationGroupId,Value="$cache_id" \
                --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)" \
                --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
                --period 300 \
                --statistics Sum \
                --query 'Datapoints[0].Sum' \
                --output text 2>/dev/null || echo "0")

            [ "$cache_hits" = "None" ] && cache_hits="0"

            if [ "${cache_hits%.*}" -gt 0 ]; then
                print_status "  Cache Performance" "${cache_hits%.*} hits" "Last 5 min" "healthy"
            fi
        else
            print_status "Redis Cluster" "$cache_id" "Not Found" "critical"
        fi
    else
        # Show ALL ElastiCache clusters
        local all_clusters=$(aws elasticache describe-replication-groups \
            --region "$AWS_REGION" \
            --query 'ReplicationGroups[*].[ReplicationGroupId,Status,AtRestEncryptionEnabled,TransitEncryptionEnabled]' \
            --output text 2>/dev/null)

        local found_any=false
        local first_cache=true
        while IFS=$'\t' read -r repl_id status at_rest_enc transit_enc; do
            [ -z "$repl_id" ] && continue

            found_any=true

            # Add separator between clusters (except before first one)
            if [ "$first_cache" = false ]; then
                echo -e "${BOLD}${CYAN}║${NC}"
            fi
            first_cache=false

            local health="healthy"
            [ "$status" != "available" ] && health="warning"

            print_status "Redis Cluster" "$repl_id" "$status" "$health"

            # Encryption at rest
            local enc_status="Disabled"
            local enc_health="warning"
            if [ "$at_rest_enc" = "True" ]; then
                enc_status="Enabled"
                enc_health="healthy"
            fi
            print_status "  Encryption at Rest" "$enc_status" "" "$enc_health"

            # Encryption in transit
            local transit_status="Disabled"
            local transit_health="warning"
            if [ "$transit_enc" = "True" ]; then
                transit_status="Enabled"
                transit_health="healthy"
            fi
            print_status "  Encryption in Transit" "$transit_status" "" "$transit_health"
        done <<< "$all_clusters"

        if [ "$found_any" = false ]; then
            print_status "ElastiCache Clusters" "None found" "" "unknown"
        fi
    fi

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to check S3 health
check_s3() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Storage (S3)${NC}"
    echo -e "${BOLD}${CYAN}╟───────────────────────────────────────────────────────────────────────────╢${NC}"

    local buckets=""
    if is_filtering_by_project; then
        buckets=$(aws s3api list-buckets \
            --query "Buckets[?contains(Name, '${PROJECT_NAME}')].[Name,CreationDate]" \
            --output text 2>/dev/null || echo "")
    else
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
                echo -e "${BOLD}${CYAN}║${NC}"
            fi
            first_bucket=false

            # Try to get bucket info (more permissive than listing)
            local bucket_exists=$(aws s3api head-bucket --bucket "$bucket_name" 2>&1)

            if [ $? -eq 0 ]; then
                # Bucket is accessible
                print_status "S3 Bucket" "$bucket_name" "Accessible" "healthy"

                # Check versioning
                local versioning=$(aws s3api get-bucket-versioning \
                    --bucket "$bucket_name" \
                    --query 'Status' \
                    --output text 2>/dev/null || echo "Disabled")

                [ "$versioning" = "None" ] && versioning="Disabled"

                local vers_health="warning"
                [ "$versioning" = "Enabled" ] && vers_health="healthy"
                print_status "  Versioning" "$versioning" "" "$vers_health"
            else
                # Check what kind of error
                if echo "$bucket_exists" | grep -q "403"; then
                    print_status "S3 Bucket" "$bucket_name" "Access Denied (403)" "warning"
                    print_status "  Note" "Needs s3:ListBucket permission" "" "unknown"
                elif echo "$bucket_exists" | grep -q "404"; then
                    print_status "S3 Bucket" "$bucket_name" "Not Found (404)" "warning"
                else
                    print_status "S3 Bucket" "$bucket_name" "Exists (limited access)" "warning"
                    print_status "  Note" "Bucket exists but access restricted" "" "unknown"
                fi
            fi
        done <<< "$buckets"

        if [ "$found_in_region" = false ]; then
            if is_filtering_by_project; then
                print_status "S3 Buckets" "None in ${AWS_REGION}" "" "unknown"
            else
                print_status "S3 Buckets" "None in ${AWS_REGION}" "" "unknown"
            fi
        fi
    else
        print_status "S3 Buckets" "None found" "" "unknown"
    fi

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to check SES health
check_ses() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Email (SES)${NC}"
    echo -e "${BOLD}${CYAN}╟───────────────────────────────────────────────────────────────────────────╢${NC}"

    local identities=$(aws ses list-identities \
        --region "$AWS_REGION" \
        --query 'Identities' \
        --output text 2>/dev/null || echo "")

    if [ -n "$identities" ]; then
        for identity in $identities; do
            local verification=$(aws ses get-identity-verification-attributes \
                --region "$AWS_REGION" \
                --identities "$identity" \
                --query "VerificationAttributes.\"${identity}\".VerificationStatus" \
                --output text 2>/dev/null || echo "Unknown")

            local health="warning"
            [ "$verification" = "Success" ] && health="healthy"

            print_status "Email Identity" "$identity" "$verification" "$health"
        done

        # Get send quota
        local quota=$(aws ses get-send-quota \
            --region "$AWS_REGION" \
            --query '[Max24HourSend,MaxSendRate,SentLast24Hours]' \
            --output text 2>/dev/null || echo "")

        if [ -n "$quota" ]; then
            IFS=$'\t' read -r max_24h max_rate sent_24h <<< "$quota"
            # Convert to integers by removing decimal points
            local max_24h_int=${max_24h%.*}
            local sent_24h_int=${sent_24h%.*}

            # Only calculate percentage if we have valid integers
            if [ -n "$max_24h_int" ] && [ "$max_24h_int" -gt 0 ] 2>/dev/null; then
                local quota_pct=$((sent_24h_int * 100 / max_24h_int))
                local quota_health="healthy"
                [ "$quota_pct" -gt 70 ] && quota_health="warning"
                [ "$quota_pct" -gt 90 ] && quota_health="critical"

                print_status "  Send Quota" "${sent_24h_int}/${max_24h_int} (${quota_pct}%)" "Last 24h" "$quota_health"
            fi
        fi
    else
        print_status "SES Identities" "None found" "" "unknown"
    fi

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to check Elastic Beanstalk health
check_elasticbeanstalk() {
    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Application (Elastic Beanstalk)${NC}"
    echo -e "${BOLD}${CYAN}╟───────────────────────────────────────────────────────────────────────────╢${NC}"

    if is_filtering_by_project; then
        # Query specific application by project name
        local app_name="${PROJECT_NAME}-app-${ENVIRONMENT}"
        local app_exists=$(aws elasticbeanstalk describe-applications \
            --region "$AWS_REGION" \
            --application-names "$app_name" \
            --query 'Applications[0].ApplicationName' \
            --output text 2>/dev/null || echo "")

        if [ -n "$app_exists" ] && [ "$app_exists" != "None" ]; then
            print_status "Application" "$app_name" "Active" "healthy"

            # Check environments
            local environments=$(aws elasticbeanstalk describe-environments \
                --region "$AWS_REGION" \
                --application-name "$app_name" \
                --query 'Environments[*].[EnvironmentName,Status,Health,CNAME]' \
                --output text 2>/dev/null || echo "")

            if [ -n "$environments" ]; then
                while IFS=$'\t' read -r env_name status health cname; do
                    local env_health="healthy"
                    [ "$health" = "Yellow" ] && env_health="warning"
                    [ "$health" = "Red" ] && env_health="critical"
                    [ "$status" != "Ready" ] && env_health="warning"

                    print_status "  Environment" "$env_name" "$status / $health" "$env_health"

                    # Check if URL is accessible
                    if timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://${cname}" | grep -q "^[23]"; then
                        print_status "    URL Health" "http://${cname}" "Responding" "healthy"
                    else
                        print_status "    URL Health" "http://${cname}" "Not Responding" "warning"
                    fi
                done <<< "$environments"
            fi
        else
            print_status "Application" "$app_name" "Not Found" "critical"
        fi
    else
        # Show ALL Elastic Beanstalk applications
        local all_apps=$(aws elasticbeanstalk describe-applications \
            --region "$AWS_REGION" \
            --query 'Applications[*].ApplicationName' \
            --output text 2>/dev/null || echo "")

        local found_any=false
        local first_app=true
        for app_name in $all_apps; do
            [ -z "$app_name" ] && continue

            found_any=true

            # Add separator between apps (except before first one)
            if [ "$first_app" = false ]; then
                echo -e "${BOLD}${CYAN}║${NC}"
            fi
            first_app=false

            print_status "Application" "$app_name" "Active" "healthy"

            # Check environments for this app
            local environments=$(aws elasticbeanstalk describe-environments \
                --region "$AWS_REGION" \
                --application-name "$app_name" \
                --query 'Environments[*].[EnvironmentName,Status,Health,CNAME]' \
                --output text 2>/dev/null || echo "")

            if [ -n "$environments" ]; then
                while IFS=$'\t' read -r env_name status health cname; do
                    [ -z "$env_name" ] && continue

                    local env_health="healthy"
                    [ "$health" = "Yellow" ] && env_health="warning"
                    [ "$health" = "Red" ] && env_health="critical"
                    [ "$status" != "Ready" ] && env_health="warning"

                    print_status "  Environment" "$env_name" "$status / $health" "$env_health"

                    # Check if URL is accessible
                    if timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://${cname}" | grep -q "^[23]"; then
                        print_status "    URL Health" "http://${cname}" "Responding" "healthy"
                    else
                        print_status "    URL Health" "http://${cname}" "Not Responding" "warning"
                    fi
                done <<< "$environments"
            fi
        done

        if [ "$found_any" = false ]; then
            print_status "EB Applications" "None found" "" "unknown"
        fi
    fi

    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════════════════╝${NC}"
}

# Function to print health summary
print_health_summary() {
    local total=$((HEALTHY + WARNING + CRITICAL + UNKNOWN))

    echo ""
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Health Summary${NC}"
    echo -e "${BOLD}${CYAN}╟───────────────────────────────────────────────────────────────────────────╢${NC}"
    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  Total Resources: ${BOLD}${total}${NC}"
    echo -e "${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}●${NC} Healthy:  ${GREEN}${HEALTHY}${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}●${NC} Warning:  ${YELLOW}${WARNING}${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${RED}●${NC} Critical: ${RED}${CRITICAL}${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${GRAY}○${NC} Unknown:  ${GRAY}${UNKNOWN}${NC}"

    # Overall health status
    echo -e "${BOLD}${CYAN}║${NC}"
    local overall_status="Healthy"
    local overall_color="${GREEN}"

    if [ "$CRITICAL" -gt 0 ]; then
        overall_status="Critical"
        overall_color="${RED}"
    elif [ "$WARNING" -gt 0 ]; then
        overall_status="Warning"
        overall_color="${YELLOW}"
    fi

    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Overall Status: ${overall_color}${overall_status}${NC}"
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
    echo "║                   AWS Infrastructure Status Dashboard                     ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Show configuration
    echo -e "${DIM}Checking health for:${NC}"
    if is_filtering_by_project; then
        echo -e "  ${CYAN}Project:${NC} ${GREEN}${PROJECT_NAME}${NC}"
        echo -e "  ${CYAN}Environment:${NC} ${GREEN}${ENVIRONMENT}${NC}"
    else
        echo -e "  ${CYAN}Mode:${NC} ${GREEN}All Resources${NC}"
    fi
    echo -e "  ${CYAN}Region:${NC} ${GREEN}${AWS_REGION}${NC}"
    echo -e "  ${CYAN}Time:${NC} ${GREEN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"

    # Check all resources
    check_vpc
    check_rds
    check_elasticache
    check_s3
    check_ses
    check_elasticbeanstalk
    print_health_summary

    # Final status
    echo ""
    if [ "$CRITICAL" -eq 0 ]; then
        echo -e "${GREEN}✓${NC} ${BOLD}Dashboard check complete${NC}"
    else
        echo -e "${RED}✗${NC} ${BOLD}Critical issues detected - please review${NC}"
    fi
    echo ""
}

# Run main
main
