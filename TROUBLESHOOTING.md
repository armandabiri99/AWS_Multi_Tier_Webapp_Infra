# Troubleshooting EC2 Connectivity Issues

## Problem
EC2 instances cannot:
- Access the internet to pull Docker images
- Connect via Session Manager
- Connect via EC2 Instance Connect Endpoint

## Root Cause Analysis

The route table configurations were fixed in Terraform, but **existing EC2 instances** were launched with the **old (broken) route tables**.

Even though Terraform updated the route tables, running instances don't automatically pick up these changes. They need to be **terminated and recreated**.

## Step-by-Step Resolution

### Step 1: Run Network Diagnostics

First, verify that the route tables are now correctly configured in AWS:

```bash
cd /home/user/AWS_Multi_Tier_Webapp_Infra
chmod +x diagnose-network.sh
./diagnose-network.sh
```

**Expected Output:**
- ✅ Internet Gateway attached
- ✅ NAT Gateway in available state
- ✅ Public route table: 0.0.0.0/0 → Internet Gateway
- ✅ Private route table: 0.0.0.0/0 → NAT Gateway
- ✅ VPC Endpoints in available state

### Step 2: Force Instance Replacement

If diagnostics show routes are correct, but instances still can't connect, you need to replace the instances:

**Option A: Using the Script (Recommended)**
```bash
chmod +x force-instance-refresh.sh
./force-instance-refresh.sh
```

**Option B: Manual Termination via AWS Console**
1. Go to EC2 → Auto Scaling Groups
2. Find `webapp-asg`
3. Go to "Instance management" tab
4. Select running instances
5. Actions → Terminate instances
6. Wait 2-3 minutes for ASG to launch new instances

**Option C: Using AWS CLI**
```bash
# Get instance IDs
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names webapp-asg \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
  --output text

# Terminate them (replace INSTANCE_IDs)
aws ec2 terminate-instances \
  --instance-ids i-xxxxx i-yyyyy \
  --region us-east-1
```

### Step 3: Monitor New Instance Launch

Watch the ASG create new instances with correct routing:

```bash
# Monitor ASG instances
watch -n 5 'aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names webapp-asg \
  --region us-east-1 \
  --query "AutoScalingGroups[0].Instances[].[InstanceId,HealthStatus,LifecycleState]" \
  --output table'
```

Wait for:
- LifecycleState: `InService`
- HealthStatus: `Healthy`

This should take **5-7 minutes**:
- 1-2 min: Instance launch
- 2-3 min: User data execution (install Docker, pull image, start container)
- 5 min: Health check grace period

### Step 4: Verify Instance Connectivity

Once instances are `InService`:

**A. Check System Logs**
```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names webapp-asg \
  --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text)

# Get console output
aws ec2 get-console-output \
  --instance-id $INSTANCE_ID \
  --region us-east-1 \
  --query 'Output' \
  --output text
```

Look for:
- ✅ `dnf update` completed successfully
- ✅ Docker installed
- ✅ `docker pull` succeeded
- ✅ Container started

**B. Test EC2 Instance Connect**

Via AWS Console:
1. Go to EC2 → Instances
2. Select the instance
3. Click "Connect"
4. Choose "EC2 Instance Connect Endpoint"
5. Select the endpoint in the dropdown
6. Click "Connect"

**C. Test Session Manager**

Via AWS Console:
1. Go to Systems Manager → Session Manager
2. Click "Start session"
3. Select your instance
4. Click "Start session"

Or via CLI:
```bash
aws ssm start-session --target $INSTANCE_ID --region us-east-1
```

**D. Check Application Health**

```bash
# Get ALB DNS
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names webapp-alb \
  --region us-east-1 \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

# Test application
curl -I http://$ALB_DNS
```

Expected: HTTP 200 OK

## Common Issues and Solutions

### Issue 1: NAT Gateway Not Available
**Symptom:** `diagnose-network.sh` shows NAT state as "pending" or "failed"

**Solution:**
```bash
# Check NAT Gateway status
aws ec2 describe-nat-gateways \
  --filter "Name=tag:Name,Values=webapp-nat" \
  --region us-east-1

# If failed, destroy and recreate
terraform destroy -target=aws_nat_gateway.nat
terraform apply -target=aws_nat_gateway.nat
```

### Issue 2: VPC Endpoints Not Working
**Symptom:** Session Manager doesn't work even after instance refresh

**Check VPC Endpoint Status:**
```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.us-east-1.ssm" \
  --region us-east-1 \
  --query 'VpcEndpoints[0].[VpcEndpointId,State,DnsEntries]'
```

**Verify DNS Resolution:**
From an instance (if you can connect):
```bash
nslookup ssm.us-east-1.amazonaws.com
# Should resolve to private IPs (10.0.x.x) if VPC endpoint is working
```

### Issue 3: Security Groups Blocking VPC Endpoints
**Symptom:** VPC endpoints exist but SSM doesn't work

**Solution:** Verify VPC endpoint security group allows HTTPS from app instances:
```bash
# Get VPC endpoint SG
VPCE_SG=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.us-east-1.ssm" \
  --region us-east-1 \
  --query 'VpcEndpoints[0].Groups[0].GroupId' \
  --output text)

# Check ingress rules
aws ec2 describe-security-groups \
  --group-ids $VPCE_SG \
  --region us-east-1 \
  --query 'SecurityGroups[0].IpPermissions'
```

Should show: Port 443 allowed from app security group

### Issue 4: User Data Failing
**Symptom:** Instance launches but health check fails

**Check cloud-init logs:**
```bash
# If you can connect via console or other means
sudo cat /var/log/cloud-init-output.log
sudo journalctl -u cloud-final
```

Common failures:
- `dnf update` timeout → routing issue
- `docker pull` timeout → routing issue
- SSM parameter access denied → IAM role issue

### Issue 5: Health Checks Failing
**Symptom:** Instances keep terminating and recreating

**Check target group health:**
```bash
TG_ARN=$(aws elbv2 describe-target-groups \
  --names webapp-tg \
  --region us-east-1 \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

aws elbv2 describe-target-health \
  --target-group-arn $TG_ARN \
  --region us-east-1
```

**Possible causes:**
- Container not running on port 8080
- Application failed to start
- Security group not allowing ALB → Instance on port 8080

## Verification Checklist

After fixing, verify all of these:

- [ ] Route tables show correct next hops (IGW for public, NAT for private)
- [ ] NAT Gateway is in "available" state
- [ ] VPC Endpoints are in "available" state
- [ ] EC2 instances are in "InService" state in ASG
- [ ] Target group shows instances as "healthy"
- [ ] Application responds via ALB DNS
- [ ] Can connect via EC2 Instance Connect Endpoint
- [ ] Can connect via Session Manager (if needed)

## Quick Reference Commands

```bash
# Get VPC ID
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=webapp-vpc" --query 'Vpcs[0].VpcId' --output text

# Get running instances
aws ec2 describe-instances --filters "Name=tag:Name,Values=webapp-ec2" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress]' --output table

# Get ALB DNS
terraform output alb_dns

# Check ASG status
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names webapp-asg --query 'AutoScalingGroups[0].Instances[]'

# Get target health
aws elbv2 describe-target-health --target-group-arn $(aws elbv2 describe-target-groups --names webapp-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
```

## Still Having Issues?

If you've completed all steps and still have issues:

1. **Collect diagnostic information:**
   ```bash
   ./diagnose-network.sh > network-diagnostics.txt
   terraform show > terraform-state.txt
   ```

2. **Check Terraform state matches AWS reality:**
   ```bash
   terraform plan
   # Should show: No changes. Your infrastructure matches the configuration.
   ```

3. **Look for dependency issues:**
   - VPC endpoints created after instances?
   - NAT Gateway not fully available when instances launched?

4. **Nuclear option - Recreate everything:**
   ```bash
   terraform destroy -target=aws_autoscaling_group.asg
   terraform destroy -target=aws_launch_template.lt
   terraform apply
   ```
