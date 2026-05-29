#!/bin/bash
# Look up the VPC ID and CIDR for an RDS DB instance.
#
# Usage:
#   ./tests/find_db_vpc_cidr.sh <db-instance-identifier>

set -e

AWS_PROFILE="${AWS_PROFILE:-sandbox}"
AWS_REGION="${AWS_REGION:-us-east-1}"

DB_IDENTIFIER="${1:-}"
if [ -z "$DB_IDENTIFIER" ]; then
  echo "Usage: $0 <db-instance-identifier>" >&2
  exit 1
fi

DB_INFO=$(AWS_PROFILE="$AWS_PROFILE" aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --region "$AWS_REGION" \
  --query "DBInstances[0].{VpcId:DBSubnetGroup.VpcId,SgIds:VpcSecurityGroups[*].VpcSecurityGroupId}" \
  --output json)

VPC_ID=$(echo "$DB_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['VpcId'])")
SG_IDS=$(echo "$DB_INFO" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin)['SgIds']))")

if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "ERROR: Could not find VPC for DB instance '${DB_IDENTIFIER}'." >&2
  exit 1
fi

VPC_CIDR=$(AWS_PROFILE="$AWS_PROFILE" aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --region "$AWS_REGION" \
  --query "Vpcs[0].CidrBlock" \
  --output text)

echo "DB Instance:  $DB_IDENTIFIER"
echo "VPC ID:       $VPC_ID"
echo "VPC CIDR:     $VPC_CIDR"
echo "Security GID: $SG_IDS"
