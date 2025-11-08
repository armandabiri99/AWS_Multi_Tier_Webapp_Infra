#!/bin/bash
# Force EC2 Instance Refresh in Auto Scaling Group
# This script terminates old instances so ASG creates new ones with fixed routes

set -e

REGION="us-east-1"
ASG_NAME="webapp-asg"

echo "=================================================="
echo "Force Instance Refresh for ASG: $ASG_NAME"
echo "=================================================="
echo ""

# Get current instances
echo "1. Getting current instances in ASG..."
INSTANCES=$(aws autoscaling describe-auto-scaling-groups \
  --region $REGION \
  --auto-scaling-group-names $ASG_NAME \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus,LifecycleState]' \
  --output text)

if [ -z "$INSTANCES" ]; then
  echo "No instances found in ASG"
  exit 0
fi

echo "$INSTANCES"
echo ""

# Count instances
INSTANCE_COUNT=$(echo "$INSTANCES" | wc -l)
echo "Found $INSTANCE_COUNT instance(s)"
echo ""

# Ask for confirmation
read -p "Do you want to terminate these instances? They will be recreated by ASG. (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "2. Terminating instances..."

echo "$INSTANCES" | while read -r INST_ID HEALTH STATE; do
  echo "Terminating $INST_ID..."
  aws ec2 terminate-instances \
    --region $REGION \
    --instance-ids $INST_ID \
    --output text > /dev/null
  echo "   ✅ Terminated: $INST_ID"
done

echo ""
echo "3. Monitoring ASG for new instances..."
echo "   Waiting for new instances to launch (this may take 2-3 minutes)..."
echo ""

sleep 10

# Monitor for new instances
for i in {1..30}; do
  NEW_INSTANCES=$(aws autoscaling describe-auto-scaling-groups \
    --region $REGION \
    --auto-scaling-group-names $ASG_NAME \
    --query 'AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus,LifecycleState]' \
    --output text)

  if [ -n "$NEW_INSTANCES" ]; then
    echo "Current instances:"
    echo "$NEW_INSTANCES"
    echo ""
  fi

  HEALTHY=$(echo "$NEW_INSTANCES" | grep -c "InService" || echo "0")

  if [ "$HEALTHY" -ge "$INSTANCE_COUNT" ]; then
    echo "✅ All instances are InService!"
    break
  fi

  echo "   Waiting... ($i/30) - $HEALTHY/$INSTANCE_COUNT InService"
  sleep 10
done

echo ""
echo "=================================================="
echo "Instance refresh complete"
echo "=================================================="
echo ""
echo "Next steps:"
echo "1. Check instance logs: AWS Console > EC2 > Instance > Actions > Monitor and troubleshoot > Get system log"
echo "2. Verify internet connectivity by checking if Docker image was pulled"
echo "3. Test application via ALB DNS name"
