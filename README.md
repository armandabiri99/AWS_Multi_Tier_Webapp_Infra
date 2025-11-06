# 🚀 AWS DevOps Infrastructure — Java WebApp on EC2 with ALB + RDS + Terraform

This project provisions a scalable, highly available environment on **AWS** to deploy a **Java web application** (packaged as a Docker image) from **Amazon ECR Public**.  
The stack is designed using **Infrastructure as Code (IaC)** with Terraform and includes:

* VPC with public/private subnets  
* Application Load Balancer (ALB)  
* Auto Scaling Group (EC2 + Launch Template)  
* RDS MySQL database (with read replicas and proxy)  
* Secure private connectivity via EC2 Instance Connect Endpoint (EIC) and SSM  
* SSM Parameter Store + Secrets Manager for credentials  
* Terraform backend with S3 + DynamoDB for remote state  

---

## 🏗️ Architecture Overview

<img width="1134" height="1027" alt="AWS Architecture Diagram" src="https://github.com/user-attachments/assets/057f8b32-8cda-429d-adce-c3b09212f035" />

* **Public layer:** Application Load Balancer (ALB) + 1 NAT Gateway  
* **Private layer:** Auto Scaling EC2 instances running Docker containers  
* **Database layer:** RDS MySQL (Multi-AZ) + read replicas via RDS Proxy  
* **Management:**  
  * **EC2 Instance Connect Endpoint (EIC)** for secure SSH over private network  
  * **AWS Systems Manager Session Manager (SSM)** for keyless, agent-based access  
  * **CloudWatch** for monitoring and metrics  
* **Image source:** [public.ecr.aws/f0y2n1c4/aws-devops:latest](https://gallery.ecr.aws/f0y2n1c4/aws-devops)

---

## ⚙️ Prerequisites

1. **AWS account** with admin or equivalent IAM privileges  
2. **Terraform** v1.6+ installed  
3. **AWS CLI** configured (`aws configure`)  
4. Remote backend ready for state management:

   ```bash
   aws s3api create-bucket --bucket terraform-backend-aws-devops --region us-east-1
   aws dynamodb create-table      --table-name terraform-lock-table      --attribute-definitions AttributeName=LockID,AttributeType=S      --key-schema AttributeName=LockID,KeyType=HASH      --billing-mode PAY_PER_REQUEST      --region us-east-1
   ```

   > 🔸 Replace `terraform-backend-aws-devops` with a globally unique bucket name.

---

## 📁 Project Structure

```
aws-infra/
├─ backend.tf              # Terraform backend (S3 + DynamoDB)
├─ providers.tf            # AWS provider config
├─ variables.tf            # Input variables
├─ terraform.tfvars        # Local variable definitions (not committed)
├─ main.tf                 # Core infrastructure definition
├─ outputs.tf              # Useful outputs (ALB, RDS endpoints, etc.)
└─ README.md               # Documentation
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
* **Health Check Path:** `/` (HTTP 200 expected)  
* **Scaling Policy:** Target tracking at 60% average CPU utilization  
* **Instance Type:** `t2.micro` (Free-tier eligible)

### Database

* **Engine:** MySQL 8.0  
* **Instance:** `db.t3.micro` (Free-tier eligible)  
* **Multi-AZ:** Enabled for failover  
* **Read replicas:** Deployed across all AZs  
* **Access:** Private-only via RDS Proxy  
* **Credentials:** Stored in **AWS Secrets Manager** (for proxy) and **SSM Parameter Store** (for config values)

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

3. **Apply the configuration**

   ```bash
   terraform apply
   ```

   Type `yes` when prompted.

4. **Wait for deployment** (~5–8 minutes).  
   Terraform outputs will include:

   ```
   alb_dns = "webapp-alb-xxxxx.us-east-1.elb.amazonaws.com"
   rds_endpoint = "webapp-mysql.xxxxx.us-east-1.rds.amazonaws.com"
   ```

5. **Test the application**

   Open in your browser:

   ```
   http://<alb_dns>
   ```

   You should see your Java web app running.

---

## 🔧 Connecting to EC2 (Private-Only)

This infrastructure **does not use public IPs or bastion hosts.**  
You can connect to EC2 instances in private subnets using one of two secure options:

### Option A — EC2 Instance Connect Endpoint (EIC)
* Provides SSH access through a private VPC endpoint.  
* The app SG allows port 22 **only from** the EIC endpoint SG.  
* No SSH keys are stored — IAM handles the authorization.  

To connect:
- **Console:** EC2 → Instances → *Connect* → **EC2 Instance Connect (Endpoint)**  
- **CLI:**  
  ```bash
  aws ec2-instance-connect send-ssh-public-key     --region <region>     --instance-id <instance-id>     --availability-zone <az>     --instance-os-user ec2-user     --ssh-public-key file://~/.ssh/id_rsa.pub
  ```

### Option B — AWS Systems Manager Session Manager (SSM)
* Provides fully keyless access over the `ssm`, `ssmmessages`, and `ec2messages` VPC endpoints.  
* Uses the IAM role **AmazonSSMManagedInstanceCore**.  
* No inbound SSH ports needed.

```bash
aws ssm start-session --target <instance-id>
```

> ✅ **Recommendation:** Use **SSM** for routine management and **EIC** only when you need direct SSH-level debugging.

---

## 🔐 Security Notes

* No public IPs or inbound Internet access to EC2/RDS.  
* **Management access only via:**
  * **SSM Session Manager** (agent-based, keyless)
  * **EC2 Instance Connect Endpoint** (IAM-based SSH through private subnets)
* All database access is routed through **RDS Proxy**.
* Sensitive data (DB credentials) stored in **SSM Parameter Store** and **AWS Secrets Manager**.
* Security groups and routes strictly isolate layers (public, private, DB).

---

## 💰 Cost Optimization

* **Free-tier eligible:**
  * `t2.micro` EC2 instances
  * `db.t3.micro` RDS instance  
* **Billable resources:**
  * 1 NAT Gateway (~$0.045/hr)
  * Application Load Balancer (~$0.0225/hr)
* ✅ Recommendations:
  * Use Terraform workspaces for dev/test separation
  * Tear down resources when idle (`terraform destroy`)

---

## 🧹 Teardown (Destroy Everything)

To destroy all resources:

```bash
terraform destroy
```

Confirm with `yes` when prompted.

---

## 🧭 Troubleshooting

| Issue | Likely Cause | Fix |
|-------|---------------|------|
| ALB targets unhealthy | App not returning HTTP 200 | Adjust app endpoint or TG health check |
| EC2 not pulling Docker image | Missing docker/awscli | Check `/var/log/cloud-init-output.log` |
| RDS connection failure | Wrong SG or credentials | Verify SSM params and RDS proxy |
| Timeout on provisioning | NAT or route misconfig | Check private route tables & IGW |

---

## 🧱 Future Enhancements

* Add **AWS WAF** in front of the ALB (for Layer 7 protection)  
* Integrate **CloudWatch dashboards & alarms**  
* Add **CI/CD pipeline** for automated deployment  
* Introduce **config drift detection** with AWS Config  

---

## 🧾 License

Apache License 2.0 — free for personal and educational use.
