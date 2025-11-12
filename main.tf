################
# Networking
################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "webapp-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "webapp-igw" }
}

resource "aws_subnet" "public" {
  for_each                = zipmap(var.azs, var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true
  tags                    = { Name = "public-${each.key}" }
}

resource "aws_subnet" "private" {
  for_each          = zipmap(var.azs, var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key
  tags              = { Name = "private-${each.key}" }
}

# Single NAT to save cost
resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id
  tags          = { Name = "webapp-nat" }
}

# Route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}
resource "aws_route_table_association" "public_assoc" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}
resource "aws_route_table_association" "private_assoc" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

################
# Security groups
################

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "alb-sg" }
}

# Ingress: HTTP 80 from anywhere (IPv4)
resource "aws_vpc_security_group_ingress_rule" "alb_http_ipv4" {
  security_group_id = aws_security_group.alb_sg.id
  description       = "Allow HTTP from anywhere (IPv4)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# Egress: allow all (IPv4)
resource "aws_vpc_security_group_egress_rule" "alb_egress_all_ipv4" {
  security_group_id = aws_security_group.alb_sg.id
  description       = "Allow all egress (IPv4)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "app_sg" {
  name   = "app-sg"
  vpc_id = aws_vpc.main.id
  tags = { Name = "app-sg" }
}

# ALB -> App on container port
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app_sg.id
  referenced_security_group_id = aws_security_group.alb_sg.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "From ALB"
}

# App -> anywhere (egress all)
resource "aws_vpc_security_group_egress_rule" "app_egress_all" {
  security_group_id = aws_security_group.app_sg.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "app_allow_ssh_from_eic" {
  security_group_id            = aws_security_group.app_sg.id
  description                  = "SSH from EC2 Instance Connect Endpoint"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.eic_endpoint_sg.id
}


resource "aws_security_group" "rds_sg" {
  name   = "rds-sg"
  vpc_id = aws_vpc.main.id
  lifecycle {
    ignore_changes = [ingress, egress]
  }

  tags = { Name = "rds-sg" }
}

resource "aws_vpc_security_group_egress_rule" "rds_egress_all" {
  security_group_id = aws_security_group.rds_sg.id
  description       = "Allow all outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Proxy → DB on 3306 (INGRESS on DB SG allowing the proxy SG)
resource "aws_vpc_security_group_ingress_rule" "db_allow_from_proxy" {
  security_group_id            = aws_security_group.rds_sg.id
  referenced_security_group_id = aws_security_group.rds_proxy_sg.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "MySQL from RDS Proxy"
}

resource "aws_security_group" "eic_endpoint_sg" {
  name        = "eic-endpoint-sg"
  description = "SG for EC2 Instance Connect Endpoints"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "eic-endpoint-sg" }
}

resource "aws_vpc_security_group_egress_rule" "eic_to_app_ssh" {
  security_group_id            = aws_security_group.eic_endpoint_sg.id
  referenced_security_group_id = aws_security_group.app_sg.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "Allow SSH to app instances"
}

resource "aws_vpc_security_group_ingress_rule" "eic_allow_clients" {
  for_each = toset(var.eic_allowed_cidrs)

  security_group_id = aws_security_group.eic_endpoint_sg.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "SSH access to EC2 Instance Connect from ${each.value}"
}

# RDS Proxy Security Groups

resource "aws_security_group" "rds_proxy_sg" {
  name        = "rds-proxy-sg"
  description = "RDS Proxy access"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "rds-proxy-sg" }
}

# App → Proxy on 3306 (INGRESS rule, new style)
resource "aws_vpc_security_group_ingress_rule" "proxy_allow_from_app" {
  security_group_id            = aws_security_group.rds_proxy_sg.id
  referenced_security_group_id = aws_security_group.app_sg.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "MySQL from app to proxy"
}

# Proxy → anywhere (EGRESS all) – adjust if you want stricter
resource "aws_vpc_security_group_egress_rule" "proxy_egress_all" {
  security_group_id = aws_security_group.rds_proxy_sg.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# SG for VPC Interface Endpoints

resource "aws_security_group" "vpce_sg" {
  name        = "vpce-sg"
  description = "Allow HTTPS from app instances to interface endpoints"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "vpce-sg" }
}

# app -> VPC endpoints : 443
resource "aws_vpc_security_group_ingress_rule" "vpce_https_from_app" {
  security_group_id            = aws_security_group.vpce_sg.id
  referenced_security_group_id = aws_security_group.app_sg.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS from app to VPC endpoints"
}

# egress all from endpoints (AWS-managed backend)
resource "aws_vpc_security_group_egress_rule" "vpce_egress_all" {
  security_group_id = aws_security_group.vpce_sg.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

################
# RDS MySQL
################
resource "aws_db_subnet_group" "db_subnets" {
  name       = "webapp-db-subnets"
  subnet_ids = [for s in aws_subnet.private : s.id]
}

resource "aws_db_instance" "mysql" {
  identifier                = "webapp-mysql"
  engine                    = var.db_engine
  engine_version            = var.db_version
  instance_class            = var.db_instance
  username                  = var.db_user
  password                  = var.db_password
  db_name                   = var.db_name
  allocated_storage         = 20
  storage_type              = "gp3"
  multi_az                  = true
  publicly_accessible       = false
  vpc_security_group_ids    = [aws_security_group.rds_sg.id]
  db_subnet_group_name      = aws_db_subnet_group.db_subnets.name
  backup_retention_period   = 7
  delete_automated_backups  = true
  deletion_protection       = false
  skip_final_snapshot       = true
  final_snapshot_identifier = null
}

# RDS Read Replicas

resource "time_sleep" "wait_for_primary_backups" {
  depends_on      = [aws_db_instance.mysql]
  create_duration = "120s" # 2 minutes is usually plenty; bump to 180s if needed
}

resource "aws_db_instance" "mysql_replicas" {
  for_each                   = toset(var.azs)
  depends_on                 = [time_sleep.wait_for_primary_backups]
  identifier                 = "webapp-mysql-rr-${replace(each.value, "-", "")}"
  replicate_source_db        = aws_db_instance.mysql.arn
  instance_class             = var.db_instance
  engine                     = var.db_engine
  engine_version             = var.db_version
  publicly_accessible        = false
  vpc_security_group_ids     = [aws_security_group.rds_sg.id]
  db_subnet_group_name       = aws_db_subnet_group.db_subnets.name
  availability_zone          = each.value
  deletion_protection        = false
  skip_final_snapshot        = true
  auto_minor_version_upgrade = true
  apply_immediately          = true
  tags                       = { Role = "read-replica", AZ = each.value }
}

# Store non-rotating params in SSM (password stored as SecureString)
resource "aws_ssm_parameter" "db_name" {
  name  = "/webapp/db/name"
  type  = "String"
  value = var.db_name
}
resource "aws_ssm_parameter" "db_user" {
  name  = "/webapp/db/user"
  type  = "String"
  value = var.db_user
}
resource "aws_ssm_parameter" "db_pass" {
  name  = "/webapp/db/password"
  type  = "SecureString"
  value = var.db_password
}

# Secret for RDS proxy auth

resource "aws_secretsmanager_secret" "db_auth" {
  name                    = "webapp/mysql/proxy-auth"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_auth_v1" {
  secret_id = aws_secretsmanager_secret.db_auth.id
  secret_string = jsonencode({
    username = var.db_user
    password = var.db_password
  })
}

# IAM Role for RDS Proxy to access RDS database

resource "aws_iam_role" "rds_proxy_role" {
  name = "webapp-rds-proxy-role"
  assume_role_policy = jsonencode({
    Version : "2012-10-17",
    Statement : [{
      Effect : "Allow",
      Principal : { Service : "rds.amazonaws.com" },
      Action : "sts:AssumeRole"
    }]
  })
  tags = { Name = "webapp-rds-proxy-role" }
}

# Minimal permissions: let the proxy read your secret
resource "aws_iam_role_policy" "rds_proxy_sm_access" {
  name = "webapp-rds-proxy-sm-access"
  role = aws_iam_role.rds_proxy_role.id
  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [
      {
        Effect : "Allow",
        Action : [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        Resource : aws_secretsmanager_secret.db_auth.arn
      },
      {
        Effect : "Allow",
        Action : [
          "kms:Decrypt"
        ],
        Resource : "*",
        Condition : {
          StringEquals : {
            "kms:ViaService" : "secretsmanager.${var.region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# RDS Proxy + Targets

resource "aws_db_proxy" "mysql" {
  name                = "webapp-mysql-proxy"
  engine_family       = "MYSQL"
  require_tls         = false
  idle_client_timeout = 1800
  debug_logging       = false

  vpc_subnet_ids         = [for s in aws_subnet.private : s.id]
  vpc_security_group_ids = [aws_security_group.rds_proxy_sg.id]

  role_arn = aws_iam_role.rds_proxy_role.arn

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.db_auth.arn
    iam_auth    = "DISABLED"
  }

  tags = { Role = "rds-proxy" }
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.mysql.name
  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 80
    max_idle_connections_percent = 50
    init_query                   = ""
  }
}

# Register the writer (primary instance only)
# RDS Proxy automatically discovers and routes to read replicas
# Do NOT register read replicas as targets - RDS Proxy doesn't support it
resource "aws_db_proxy_target" "writer" {
  db_proxy_name          = aws_db_proxy.mysql.name
  target_group_name      = aws_db_proxy_default_target_group.this.name
  db_instance_identifier = aws_db_instance.mysql.identifier
}

# Note: RDS Proxy READ_ONLY endpoints are not supported for standalone RDS instances
# READ_ONLY endpoints work with Aurora clusters, but not with RDS instances + read replicas
# For now, applications should use the writer endpoint for both reads and writes
# RDS Proxy provides connection pooling and will distribute connections efficiently

# Uncomment below if using Aurora instead of standalone RDS:
# resource "aws_db_proxy_endpoint" "reader" {
#   db_proxy_name          = aws_db_proxy.mysql.name
#   db_proxy_endpoint_name = "webapp-mysql-proxy-reader"
#   vpc_subnet_ids         = [for s in aws_subnet.private : s.id]
#   vpc_security_group_ids = [aws_security_group.rds_proxy_sg.id]
#   target_role            = "READ_ONLY"
#   tags                   = { Role = "rds-proxy-reader" }
# }

################
# IAM for EC2 (SSM + SSM Param read)
################
data "aws_iam_policy_document" "ssm_params_read" {
  statement {
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory", "ssm:DescribeParameters"]
    resources = [
      aws_ssm_parameter.db_name.arn,
      aws_ssm_parameter.db_user.arn,
      aws_ssm_parameter.db_pass.arn
    ]
  }
}

resource "aws_iam_role" "ec2_role" {
  name = "webapp-ec2-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_policy" "param_read" {
  name   = "webapp-ssm-params-read"
  policy = data.aws_iam_policy_document.ssm_params_read.json
}

resource "aws_iam_role_policy_attachment" "param_read_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.param_read.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "webapp-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

################
# ALB + Target Group + Listener
################
resource "aws_lb" "alb" {
  name               = "webapp-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for s in aws_subnet.public : s.id]
}

resource "aws_lb_target_group" "tg" {
  name     = "webapp-tg"
  port     = var.container_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200-399"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

################
# Launch Template + ASG
################
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_launch_template" "lt" {
  name_prefix   = "webapp-lt-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  update_default_version = true
  depends_on = [
    aws_vpc_endpoint.ssm,
    aws_vpc_endpoint.ssmmessages,
    aws_vpc_endpoint.ec2messages,
    aws_vpc_endpoint.ecr_api,
    aws_vpc_endpoint.ecr_dkr,
    aws_vpc_endpoint.s3,
    aws_ssm_parameter.db_name,
    aws_ssm_parameter.db_user,
    aws_ssm_parameter.db_pass,
    aws_db_proxy_target.writer,
    aws_db_proxy_default_target_group.this
  ]

  # Increase root volume size for Docker images
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-EOF
  #!/bin/bash
  set -euxo pipefail

  #log to both console and a file for easy troubleshooting
  exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

  dnf update -y || true

  dnf install -y docker awscli ec2-instance-connect amazon-ssm-agent || true

  systemctl restart sshd || true

  systemctl enable --now docker || true

  usermod -aG docker ec2-user || true


  systemctl enable --now amazon-ssm-agent || true

  # Retrieve database credentials from SSM Parameter Store
  DB_NAME=$(aws ssm get-parameter --name "${aws_ssm_parameter.db_name.name}" --region ${var.region} --query 'Parameter.Value' --output text)
  DB_USER=$(aws ssm get-parameter --name "${aws_ssm_parameter.db_user.name}" --region ${var.region} --query 'Parameter.Value' --output text)
  DB_PASS=$(aws ssm get-parameter --name "${aws_ssm_parameter.db_pass.name}" --with-decryption --region ${var.region} --query 'Parameter.Value' --output text)

  # Start application container
  docker rm -f webapp || true
  docker pull ${var.ecr_public_image}
  docker run -d --restart=always --name webapp \
    -p ${var.container_port}:${var.container_port} \
    -e DB_HOST="${aws_db_proxy.mysql.endpoint}" \
    -e DB_PORT="3306" \
    -e DB_NAME="$${DB_NAME}" \
    -e DB_USER="$${DB_USER}" \
    -e DB_PASS="$${DB_PASS}" \
    ${var.ecr_public_image}

  # success marker so you can confirm in cloud-init logs
  echo "USER-DATA COMPLETE"
EOF
  )
}

resource "aws_autoscaling_group" "asg" {
  name                      = "webapp-asg"
  desired_capacity          = var.asg_desired
  min_size                  = var.asg_min
  max_size                  = var.asg_max
  vpc_zone_identifier       = [for s in aws_subnet.private : s.id]
  health_check_type         = "ELB"
  health_check_grace_period = 300
  target_group_arns         = [aws_lb_target_group.tg.arn]
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }
  tag {
    key                 = "Name"
    value               = "webapp-ec2"
    propagate_at_launch = true
  }
}

# CPU-based scaling policy
resource "aws_autoscaling_policy" "cpu_target" {
  name                   = "cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}
# Instance Connect Endpoint Creation
# NOTE: By default, only one EIC endpoint is created (in first AZ) due to service quota limits.
# EIC endpoints work across AZs in the same VPC, so one endpoint can connect to instances in any AZ.
# To create endpoints in multiple AZs, set eic_endpoint_azs variable and request quota increase.

locals {
  eic_target_azs = length(var.eic_endpoint_azs) > 0 ? var.eic_endpoint_azs : [element(var.azs, 0)]
}

resource "aws_ec2_instance_connect_endpoint" "this" {
  for_each = {
    for az, subnet in aws_subnet.private : az => subnet
    if contains(local.eic_target_azs, az)
  }
  subnet_id          = each.value.id
  security_group_ids = [aws_security_group.eic_endpoint_sg.id]

  # When false (default), instances see the endpoint IP as source.
  # Keep it false so you can simply allow the endpoint SG on instance SGs.

  preserve_client_ip = false

  tags = {
    Name = "eic-endpoint-${each.key}" # e.g., eic-endpoint-us-west-2a
  }
}

# Interface Endpoints for Private Connectivity

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true
  tags                = { Name = "vpce-ssm" }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true
  tags                = { Name = "vpce-ssmmessages" }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true
  tags                = { Name = "vpce-ec2messages" }
}

# ECR Endpoints for Docker image pulls
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true
  tags                = { Name = "vpce-ecr-api" }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce_sg.id]
  private_dns_enabled = true
  tags                = { Name = "vpce-ecr-dkr" }
}

# S3 Gateway Endpoint for ECR image layers
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "vpce-s3" }
}
