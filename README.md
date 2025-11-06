# 🚀 AWS DevOps Infrastructure — Java WebApp on EC2 with ALB + RDS + Terraform

This project provisions a scalable, highly available environment on **AWS** to deploy a **Java web application** (packaged as a Docker image) from **Amazon ECR Public**.
The stack includes:

* VPC with public/private subnets
* Application Load Balancer (ALB)
* Auto Scaling Group (EC2 + Launch Template)
* RDS MySQL database
* SSM Parameter Store for DB credentials
* Terraform for IaC (S3 + DynamoDB backend)

---

## 🏗️ Architecture Overview

<img width="1134" height="1027" alt="Screenshot 2025-11-06 at 12 39 49 AM" src="https://github.com/user-attachments/assets/057f8b32-8cda-429d-adce-c3b09212f035" />


* **Public layer:** ALB + 1 NAT Gateway
* **Private layer:** EC2 instances (Auto Scaling Group) running Docker containers
* **Database layer:** RDS MySQL instance (private access only)
* **Management:** SSM Session Manager (no SSH keys), CloudWatch metrics
* **Image source:** [public.ecr.aws/f0y2n1c4/aws-devops:latest](https://gallery.ecr.aws/f0y2n1c4/aws-devops)

---

## ⚙️ Prerequisites

1. **AWS account** with admin or equivalent IAM privileges.
2. **Terraform** v1.6+ installed.
3. **AWS CLI** configured (`aws configure`).
4. Remote state backend ready:

   ```bash
   aws s3api create-bucket --bucket terraform-backend-aws-devops --region us-east-1
   aws dynamodb create-table \
     --table-name terraform-lock-table \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST \
     --region us-east-1
   ```

   (Only needed once per account.)
The S3 bucket name needs to be replaced. Please choose a new, globally unique name.
---

## 📁 Project Structure

```
aws-infra/
├─ backend.tf              # Terraform backend (S3 + DynamoDB)
├─ providers.tf            # AWS provider config
├─ variables.tf            # Input variables
├─ terraform.tfvars        # Project-specific values you need to add locally
├─ main.tf                 # Core infrastructure definition
├─ outputs.tf              # Useful outputs (ALB, RDS endpoints)
└─ README.md               # This file
```

---

## 🧩 Key Configurations

### Terraform Backend

* **S3 bucket:** `terraform-backend-aws-devops`
* **DynamoDB table:** `terraform-lock-table`
* **Region:** `us-east-1`

### Application

* **Container Image:** `public.ecr.aws/f0y2n1c4/aws-devops:latest`
* **Port:** `8080`
* **Health Check Path:** `/` (returns HTTP 200)
* **Scaling Policy:** Target tracking on 60% average CPU utilization
* **Instance Type:** `t2.micro` (Free-tier eligible)

### Database

* **Engine:** MySQL 8.0
* **Instance:** `db.t3.micro` (Free-tier eligible)
* **DB Name:** `webapp_db`
* **DB User:** `webapp_user`
* **Password:** passed with terraform.tfvars and then stored in AWS SSM Parameter Store
* **Access:** private only (from EC2 in private subnets)

---

## 🚀 Deployment Steps

1. **Initialize Terraform**

   ```bash
   terraform init
   ```

2. **Preview the changes**

   ```bash
   terraform plan
   ```

3. **Apply configuration**

   ```bash
   terraform apply
   ```

   Type `yes` when prompted.

4. **Wait for deployment** (takes ~5–8 minutes).
   On completion, you’ll see:

   ```
   alb_dns = "webapp-alb-xxxxx.us-east-1.elb.amazonaws.com"
   rds_endpoint = "webapp-mysql.xxxxx.us-east-1.rds.amazonaws.com"
   ```

5. **Test the app**

   * Open in your browser:

     ```
     http://<alb_dns>
     ```
   * You should see your Java web app running.

6. **Connect to EC2 via Session Manager**

   ```bash
   aws ssm start-session --target <instance-id>
   ```

---


## 🔐 Security Notes

* No public SSH access — all management via AWS Systems Manager Session Manager.
* ALB handles all incoming traffic on port 80.
* Private subnets host EC2 and RDS (not directly reachable from the Internet).
* DB credentials and names stored securely in **AWS SSM Parameter Store**.

---

## 💰 Cost Optimization

* **Free-tier eligible resources:**

  * `t2.micro` EC2
  * `db.t3.micro` RDS
* **Paid components:**

  * 1 NAT Gateway (~$0.045/hr)
  * ALB (~$0.0225/hr)
* ✅ To save costs:

  * Run only when needed
  * Use `terraform destroy` to tear down when idle

---

## 🧹 Teardown (Destroy Everything)

When done, destroy resources to avoid charges:

```bash
terraform destroy
```

Type `yes` when prompted.

---

## 🧭 Troubleshooting

| Issue                       | Likely Cause                           | Fix                                                     |
| --------------------------- | -------------------------------------- | ------------------------------------------------------- |
| ALB shows unhealthy targets | `/` endpoint not returning HTTP 200    | Adjust app or change TG health check to TCP:8080        |
| EC2 not pulling image       | Docker not installed or ECR auth issue | Check user_data logs (`/var/log/cloud-init-output.log`) |
| RDS connection failure      | Security group or wrong credentials    | Verify SSM parameters and app env vars                  |
| Terraform timeout           | NAT or Internet gateway misconfig      | Ensure route tables and IGW association are correct     |

---

## 🧾 License

Apache License 2.0 — free for personal and educational use.

---
