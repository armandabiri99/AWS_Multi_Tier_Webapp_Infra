#!/bin/bash
# Network Diagnostics Script for AWS Multi-Tier Infrastructure
# This script checks all networking components to identify connectivity issues

set -e

REGION="us-east-1"
echo "=================================================="
echo "AWS Network Diagnostics - Region: $REGION"
echo "=================================================="
echo ""

# Get VPC ID
echo "1. Getting VPC Information..."
VPC_ID=$(aws ec2 describe-vpcs \
  --region $REGION \
  --filters "Name=tag:Name,Values=webapp-vpc" \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "❌ ERROR: VPC not found"
  exit 1
fi

echo "✅ VPC ID: $VPC_ID"
echo ""

# Check Internet Gateway
echo "2. Checking Internet Gateway..."
IGW_ID=$(aws ec2 describe-internet-gateways \
  --region $REGION \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)

if [ "$IGW_ID" = "None" ] || [ -z "$IGW_ID" ]; then
  echo "❌ ERROR: Internet Gateway not attached to VPC"
else
  echo "✅ Internet Gateway: $IGW_ID (attached to VPC)"
fi
echo ""

# Check NAT Gateway
echo "3. Checking NAT Gateway..."
NAT_INFO=$(aws ec2 describe-nat-gateways \
  --region $REGION \
  --filter "Name=vpc-id,Values=$VPC_ID" \
  --query 'NatGateways[0].[NatGatewayId,State,SubnetId]' \
  --output text)

if [ "$NAT_INFO" = "None" ] || [ -z "$NAT_INFO" ]; then
  echo "❌ ERROR: NAT Gateway not found"
else
  NAT_ID=$(echo $NAT_INFO | awk '{print $1}')
  NAT_STATE=$(echo $NAT_INFO | awk '{print $2}')
  NAT_SUBNET=$(echo $NAT_INFO | awk '{print $3}')

  if [ "$NAT_STATE" = "available" ]; then
    echo "✅ NAT Gateway: $NAT_ID (State: $NAT_STATE)"
    echo "   Subnet: $NAT_SUBNET"
  else
    echo "⚠️  NAT Gateway: $NAT_ID (State: $NAT_STATE) - NOT AVAILABLE"
  fi
fi
echo ""

# Check Route Tables
echo "4. Checking Route Tables..."
echo ""

# Public Route Table
echo "   a) Public Route Table:"
PUBLIC_RT_ID=$(aws ec2 describe-route-tables \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*public*" \
  --query 'RouteTables[0].RouteTableId' \
  --output text 2>/dev/null || echo "")

if [ -z "$PUBLIC_RT_ID" ] || [ "$PUBLIC_RT_ID" = "None" ]; then
  # Try finding by routes
  PUBLIC_RT_ID=$(aws ec2 describe-route-tables \
    --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[?Routes[?GatewayId=='$IGW_ID']].RouteTableId | [0]" \
    --output text)
fi

if [ -z "$PUBLIC_RT_ID" ] || [ "$PUBLIC_RT_ID" = "None" ]; then
  echo "   ❌ Public route table not found"
else
  echo "   Route Table ID: $PUBLIC_RT_ID"
  echo "   Routes:"
  aws ec2 describe-route-tables \
    --region $REGION \
    --route-table-ids $PUBLIC_RT_ID \
    --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId,State]' \
    --output table

  # Check if 0.0.0.0/0 points to IGW
  IGW_ROUTE=$(aws ec2 describe-route-tables \
    --region $REGION \
    --route-table-ids $PUBLIC_RT_ID \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
    --output text)

  if [ "$IGW_ROUTE" = "$IGW_ID" ]; then
    echo "   ✅ Default route (0.0.0.0/0) correctly points to IGW"
  else
    echo "   ❌ ERROR: Default route does NOT point to IGW (points to: $IGW_ROUTE)"
  fi
fi
echo ""

# Private Route Table
echo "   b) Private Route Table:"
PRIVATE_RT_ID=$(aws ec2 describe-route-tables \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*private*" \
  --query 'RouteTables[0].RouteTableId' \
  --output text 2>/dev/null || echo "")

if [ -z "$PRIVATE_RT_ID" ] || [ "$PRIVATE_RT_ID" = "None" ]; then
  # Try finding by NAT routes
  PRIVATE_RT_ID=$(aws ec2 describe-route-tables \
    --region $REGION \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[?Routes[?NatGatewayId=='$NAT_ID']].RouteTableId | [0]" \
    --output text)
fi

if [ -z "$PRIVATE_RT_ID" ] || [ "$PRIVATE_RT_ID" = "None" ]; then
  echo "   ❌ Private route table not found"
else
  echo "   Route Table ID: $PRIVATE_RT_ID"
  echo "   Routes:"
  aws ec2 describe-route-tables \
    --region $REGION \
    --route-table-ids $PRIVATE_RT_ID \
    --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId,State]' \
    --output table

  # Check if 0.0.0.0/0 points to NAT
  NAT_ROUTE=$(aws ec2 describe-route-tables \
    --region $REGION \
    --route-table-ids $PRIVATE_RT_ID \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId" \
    --output text)

  if [ "$NAT_ROUTE" = "$NAT_ID" ]; then
    echo "   ✅ Default route (0.0.0.0/0) correctly points to NAT Gateway"
  else
    echo "   ❌ ERROR: Default route does NOT point to NAT Gateway (points to: $NAT_ROUTE)"
  fi
fi
echo ""

# Check VPC Endpoints
echo "5. Checking VPC Endpoints..."
ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[].[ServiceName,State,VpcEndpointType]' \
  --output text)

if [ -z "$ENDPOINTS" ]; then
  echo "⚠️  No VPC endpoints found"
else
  echo "$ENDPOINTS" | while read -r line; do
    SERVICE=$(echo $line | awk '{print $1}' | sed 's/com.amazonaws.'$REGION'.//g')
    STATE=$(echo $line | awk '{print $2}')
    TYPE=$(echo $line | awk '{print $3}')

    if [ "$STATE" = "available" ]; then
      echo "   ✅ $SERVICE ($TYPE): $STATE"
    else
      echo "   ⚠️  $SERVICE ($TYPE): $STATE"
    fi
  done
fi
echo ""

# Check EC2 Instances
echo "6. Checking EC2 Instances..."
INSTANCES=$(aws ec2 describe-instances \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,SubnetId,PrivateIpAddress,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output text)

if [ -z "$INSTANCES" ]; then
  echo "⚠️  No running instances found"
else
  echo "Running instances:"
  echo "$INSTANCES" | while read -r INST_ID SUBNET_ID PRIVATE_IP STATE NAME; do
    echo "   Instance: $INST_ID ($NAME)"
    echo "   Private IP: $PRIVATE_IP"
    echo "   Subnet: $SUBNET_ID"

    # Check which route table this subnet uses
    RT_ID=$(aws ec2 describe-route-tables \
      --region $REGION \
      --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
      --query 'RouteTables[0].RouteTableId' \
      --output text)

    if [ -z "$RT_ID" ] || [ "$RT_ID" = "None" ]; then
      echo "   Route Table: Using main/default"
    else
      echo "   Route Table: $RT_ID"
    fi
    echo ""
  done
fi
echo ""

# Check EC2 Instance Connect Endpoints
echo "7. Checking EC2 Instance Connect Endpoints..."
EIC_ENDPOINTS=$(aws ec2 describe-instance-connect-endpoints \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'InstanceConnectEndpoints[].[InstanceConnectEndpointId,State,SubnetId]' \
  --output text 2>/dev/null || echo "")

if [ -z "$EIC_ENDPOINTS" ]; then
  echo "⚠️  No EC2 Instance Connect Endpoints found"
else
  echo "$EIC_ENDPOINTS" | while read -r EIC_ID STATE SUBNET; do
    if [ "$STATE" = "create-complete" ]; then
      echo "   ✅ $EIC_ID: $STATE (Subnet: $SUBNET)"
    else
      echo "   ⚠️  $EIC_ID: $STATE (Subnet: $SUBNET)"
    fi
  done
fi
echo ""

# Summary and Recommendations
echo "=================================================="
echo "SUMMARY & RECOMMENDATIONS"
echo "=================================================="
echo ""

# Check for common issues
ISSUES_FOUND=0

if [ "$NAT_STATE" != "available" ]; then
  echo "❌ NAT Gateway is not in 'available' state"
  echo "   Action: Wait for NAT Gateway to become available or recreate it"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [ "$IGW_ROUTE" != "$IGW_ID" ]; then
  echo "❌ Public subnets don't route to Internet Gateway"
  echo "   Action: Fix public route table to point 0.0.0.0/0 to IGW"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [ "$NAT_ROUTE" != "$NAT_ID" ]; then
  echo "❌ Private subnets don't route to NAT Gateway"
  echo "   Action: Fix private route table to point 0.0.0.0/0 to NAT Gateway"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
fi

if [ $ISSUES_FOUND -eq 0 ]; then
  echo "✅ No critical routing issues detected"
  echo ""
  echo "If instances still can't access internet:"
  echo "1. Check security groups allow outbound traffic"
  echo "2. Terminate old instances and let ASG create new ones"
  echo "3. Check VPC endpoint security groups allow port 443 from app instances"
  echo "4. Verify instance IAM role has necessary permissions"
else
  echo ""
  echo "Found $ISSUES_FOUND critical issue(s) - see above for actions"
fi

echo ""
echo "=================================================="
echo "Diagnostics Complete"
echo "=================================================="
