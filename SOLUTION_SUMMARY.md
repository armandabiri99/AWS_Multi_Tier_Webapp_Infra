# EC2 Connectivity Issues - Root Cause Analysis & Solution

## Problem Statement
EC2 instances in Auto Scaling Group were:
- Not able to reach public internet
- Unable to pull ECR images
- Failing health checks continuously
- Could not connect via EC2 Instance Connect or Session Manager

## Investigation Process

### Initial Hypothesis: Network Routing Issues
We initially suspected route table misconfigurations preventing internet access.

**Fixes Applied:**
1. ✅ Fixed public route table: Changed from `nat_gateway_id` to `gateway_id` for Internet Gateway
2. ✅ Fixed private route table: Changed from `gateway_id` to `nat_gateway_id` for NAT Gateway

### Additional Infrastructure Improvements
3. ✅ Added `health_check_grace_period = 300` to ASG
4. ✅ Added VPC endpoints for ECR (ecr.api, ecr.dkr) and S3
5. ✅ Added ECR IAM permissions to EC2 role
6. ✅ Fixed Secrets Manager `recovery_window_in_days = 0`
7. ✅ Fixed RDS Proxy targets to use `.identifier` instead of `.id`

### Actual Root Cause: Disk Space Exhaustion ⚠️

After analyzing EC2 instance logs, we discovered:

**Network connectivity was WORKING PERFECTLY:**
- ✅ Packages downloaded from Amazon repositories (49 MB)
- ✅ Docker installed successfully
- ✅ SSM parameters retrieved (VPC endpoints working)
- ✅ Docker pull from ECR Public started successfully

**Real Issue:**
```
[77.193396] cloud-init[2466]: failed to register layer: write /opt/java/openjdk/lib/modules: no space left on device
```

The default 8GB root volume was **too small** for:
- Amazon Linux 2023 OS (~3-4 GB)
- Docker and dependencies (~2 GB)
- Java-based application Docker image (~4-5 GB)

## Final Solution

Increased root volume size in launch template:

```hcl
block_device_mappings {
  device_name = "/dev/xvda"
  ebs {
    volume_size           = 20  # Increased from 8GB to 20GB
    volume_type           = "gp3"
    delete_on_termination = true
  }
}
```

## Summary of All Changes

| Issue | Fix | Status |
|-------|-----|--------|
| Route table configurations | Fixed gateway attributes | ✅ Applied |
| ASG health check grace period | Added 300s grace period | ✅ Applied |
| ECR VPC endpoints | Added ecr.api, ecr.dkr, s3 | ✅ Applied |
| ECR IAM permissions | Added ECR ReadOnly policy | ✅ Applied |
| Secrets Manager recovery | Set recovery_window_in_days = 0 | ✅ Applied |
| RDS Proxy targets | Use .identifier instead of .id | ✅ Applied |
| RDS Proxy read replicas | Removed unsupported replica registration | ✅ Applied |
| **Root volume size** | **Increased from 8GB to 20GB** | ✅ **Applied** |

## Deployment Steps

1. **Pull latest changes:**
   ```bash
   git pull origin claude/fix-ec2-internet-connectivity-011CUtpm9AUZhfetyiEE6Fke
   ```

2. **Apply Terraform:**
   ```bash
   terraform apply
   ```

3. **Force instance refresh** (since launch template changed):
   ```bash
   # Option A: Manual termination via AWS Console
   # EC2 > Auto Scaling Groups > webapp-asg > Instance management > Terminate

   # Option B: Using script
   ./force-instance-refresh.sh

   # Option C: AWS CLI
   aws autoscaling start-instance-refresh \
     --auto-scaling-group-name webapp-asg \
     --region us-east-1
   ```

4. **Wait for new instances** (~7-8 minutes):
   - 1-2 min: Instance launch
   - 2-3 min: User data execution (now with enough disk space)
   - 5 min: Health check grace period

5. **Verify deployment:**
   ```bash
   # Get ALB DNS
   ALB_DNS=$(terraform output -raw alb_dns)

   # Test application
   curl -I http://$ALB_DNS
   # Expected: HTTP 200 OK
   ```

## Lessons Learned

1. **Always check instance logs first** - They provide the most accurate diagnosis
2. **Disk space matters** - Docker images can be large, especially Java-based ones
3. **Network fixes were valuable** - Even though not the root cause, they improved the infrastructure
4. **VPC endpoints reduce NAT costs** - ECR pulls are now faster and cheaper
5. **Health check grace period is critical** - Prevents premature instance termination

## Expected Outcome

After applying the volume size fix:
- ✅ Instances launch successfully
- ✅ Docker image pulls completely
- ✅ Application starts and responds to health checks
- ✅ Instances remain healthy and don't recreate
- ✅ Application accessible via ALB
- ✅ EC2 Instance Connect works
- ✅ Session Manager works (if needed)

## Cost Impact

**Added monthly costs:**
- 3 Interface VPC Endpoints: ~$22/month
- Increased EBS volume (12GB extra per instance): ~$1/month per instance
- **Total additional cost:** ~$23-25/month

**Cost savings:**
- Reduced NAT Gateway data transfer: ~$10-30/month
- **Net cost:** Minimal increase for significantly better reliability and performance

## Files Modified

1. `main.tf` - All infrastructure fixes
2. `diagnose-network.sh` - Network diagnostic script
3. `force-instance-refresh.sh` - Instance refresh automation
4. `TROUBLESHOOTING.md` - Comprehensive troubleshooting guide
5. `SOLUTION_SUMMARY.md` - This document

## Verification Checklist

After deployment, verify:
- [ ] Route tables configured correctly (run `./diagnose-network.sh`)
- [ ] NAT Gateway in "available" state
- [ ] VPC Endpoints in "available" state
- [ ] EC2 instances launch successfully
- [ ] Docker image pull completes (check instance logs)
- [ ] Instances show "InService" in ASG
- [ ] Target group shows instances as "healthy"
- [ ] Application responds via ALB DNS
- [ ] EC2 Instance Connect works
- [ ] No instances recreating in a loop

## Support Resources

- **Network Diagnostics:** `./diagnose-network.sh`
- **Instance Refresh:** `./force-instance-refresh.sh`
- **Troubleshooting Guide:** `TROUBLESHOOTING.md`
- **Instance Logs:** AWS Console > EC2 > Instance > Actions > Monitor and troubleshoot > Get system log

## Conclusion

The issue was **disk space exhaustion**, not network connectivity. However, all the networking fixes we applied have significantly improved the infrastructure's reliability, performance, and cost efficiency. The instance should now deploy successfully with the increased 20GB root volume.
