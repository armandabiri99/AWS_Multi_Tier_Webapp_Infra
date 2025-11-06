variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnets" {
  type    = list(string)
  default = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# App container
variable "ecr_public_image" {
  type    = string
  default = "public.ecr.aws/f0y2n1c4/aws-devops:latest"
}

variable "container_port" {
  type    = number
  default = 8080
}

# ASG
variable "instance_type" {
  type    = string
  default = "t2.micro"
}

variable "asg_min" {
  type    = number
  default = 1
}

variable "asg_desired" {
  type    = number
  default = 1
}

variable "asg_max" {
  type    = number
  default = 1
}

# DB
variable "db_name" {
  type    = string
  default = "webapp_db"
}

variable "db_user" {
  type    = string
  default = "webapp_user"
}

variable "db_engine" {
  type    = string
  default = "mysql"
}

variable "db_version" {
  type    = string
  default = "8.0"
}

variable "db_instance" {
  type    = string
  default = "db.t3.micro"
}

variable "db_password" {
  type    = string
  default = "123&awscloud"
}
