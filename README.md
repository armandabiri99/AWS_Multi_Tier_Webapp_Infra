# 🚀 AWS DevOps Infrastructure — Java WebApp on EC2 with ALB + RDS + Terraform

This project provisions a scalable, highly available environment on **AWS** to deploy a **Java web application** (packaged as a Docker image) from **Amazon ECR Public**.  
The stack is designed using **Infrastructure as Code (IaC)** with Terraform and includes:

* VPC with public/private subnets  
* Application Load Balancer (ALB)  
* Auto Scaling Group (EC2 + Launch Template)  
* RDS MySQL database (with read replicas and proxy)  
* Secure private connectivity via EC2 Instance Connect Endpoint (EIC) and SSM  
* SSM Parameter Store + Secrets Manager for credentials  
* Automated Terraform backend (S3 + DynamoDB) provisioning  

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

---

## ☁️ Automated Terraform Backend Setup

This project includes a helper configuration located in:

```
s3-dynamo-backend/
└── backendinfra.tf
```

That file automatically creates:

* An **S3 bucket** (`terraform-backend-aws-devops`) for storing Terraform state  
  * Versioning enabled  
  * AES-256 encryption enforced  
* A **DynamoDB table** (`terraform-lock-table`) for state locking and consistency  

### 🔧 Usage

Run the following before initializing your main infrastructure:

```bash
cd s3-dynamo-backend
terraform init
terraform apply -auto-approve
```

This provisions the backend automatically.  
Once done, move back to your main directory and initialize Terraform using that backend:

```bash
cd ..
terraform init
```

> 🔸 You can customize the bucket and table names in `backendinfra.tf` as needed.

---

## 📁 Project Structure

```
aws-infra/
├─ s3-dynamo-backend/         # Automated backend creation (S3 + DynamoDB)
│  └─ backendinfra.tf
├─ backend.tf                 # Backend configuration for main stack
├─ providers.tf               # AWS provider configuration
├─ variables.tf               # Input variables
├─ main.tf                    # Core infrastructure definition
├─ outputs.tf                 # Useful outputs (ALB, RDS endpoints, etc.)
├─ .gitignore                 # Excludes .terraform, tfstate, etc.
└─ README.md                  # This file
```

---

## 🧩 Key Configurations

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

3. **Apply configuration**

   ```bash
   terraform apply
   ```

   Confirm with `yes` when prompted.

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

---

## 🔧 Connecting to EC2 (Private-Only)

This infrastructure uses **no public IPs or bastion hosts**.  
Access to EC2 instances in private subnets is provided securely via:

### Option A — EC2 Instance Connect Endpoint (EIC)
* Provides SSH access over private VPC networking.  
* The EC2 SG allows port 22 **only from** the EIC endpoint SG.  
* IAM controls authorization (no stored SSH keys).

### Option B — AWS Systems Manager Session Manager (SSM)
* Provides keyless management access through VPC interface endpoints:  
  `ssm`, `ssmmessages`, `ec2messages`.  
* Uses IAM role `AmazonSSMManagedInstanceCore`.

```bash
aws ssm start-session --target <instance-id>
```

> ✅ Recommended: Use **SSM** for standard management; **EIC** for deep debugging.

---

## 🔐 Security Notes

* No public inbound traffic to EC2 or RDS.  
* Private subnets only; ALB resides in public subnets.  
* Management access restricted to **EIC** and **SSM**.  
* Database connections go through **RDS Proxy** only.  
* Credentials stored securely in **SSM Parameter Store** and **Secrets Manager**.  

---

## 💰 Cost Optimization

* **Free-tier eligible:**
  * `t2.micro` EC2
  * `db.t3.micro` RDS
* **Billable resources:**
  * NAT Gateway (~$0.045/hr)
  * ALB (~$0.0225/hr)
* ✅ To minimize cost:
  * Destroy resources when idle  
  * Use workspaces for isolated environments

---

## 🧹 Teardown (Destroy Everything)

To destroy all infrastructure:

```bash
terraform destroy
```

Type `yes` when prompted.

---

## 🧱 Future Enhancements

* Add **AWS WAF** for ALB layer protection  
* Integrate **CloudWatch dashboards and alarms**  
* Automate deployments with CI/CD pipelines  
* Add **drift detection** with AWS Config  

---

## 🧾 License

Apache License 2.0 — free for personal and educational use.
