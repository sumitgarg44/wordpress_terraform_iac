provider "aws" {
  region = local.region
}

locals {
  region = "eu-west-1"
  env    = "dev"
  name   = "wp"
  tags = {
    Terraform   = "true"
    Environment = "dev"
    CMS         = "wordpress"
  }

}


#############################################################
# Creates VPC
#############################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.14.0"

  name                         = "${local.name}-vpc"
  cidr                         = "10.0.0.0/16"
  azs                          = ["${local.region}a", "${local.region}b"]
  create_database_subnet_group = "true"
  public_subnets               = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets              = ["10.0.3.0/24", "10.0.4.0/24"]
  database_subnets             = ["10.0.5.0/24", "10.0.6.0/24"]
  enable_dns_hostnames         = "true"

  tags = local.tags
}

###############################################################
# Creates Security Group
###############################################################
module "db_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "4.9.0"

  name        = "${local.name}-db-sg"
  description = "MySQL Security Group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "MySQL access from within VPC"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]
  tags = local.tags
}

module "efs_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "4.9.0"

  name        = "${local.name}-efs-sg"
  description = "EFS Security Group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_cidr_blocks = [module.vpc.vpc_cidr_block]
  ingress_rules       = ["all-all"]

  tags = local.tags
}

module "ssh_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "4.9.0"

  name        = "${local.name}-ssh-sg"
  description = "SSH Security Group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_with_cidr_blocks = [
    {
      description = "SSH access from anywhere"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      description = "Acess from within VPC"
      from_port   = 0
      to_port     = 65535
      protocol    = "tcp"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]

  # egress
  egress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules       = ["all-all"]

  tags = local.tags
}

module "http_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "4.9.0"

  name        = "${local.name}-http-sg"
  description = "Frontend Security Group"
  vpc_id      = module.vpc.vpc_id

  # ingress
  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp"]

  # egress
  egress_with_cidr_blocks = [
    {
      description = "Access from within VPC"
      from_port   = 0
      to_port     = 65535
      protocol    = "tcp"
      cidr_blocks = module.vpc.vpc_cidr_block
    },
  ]

  tags = local.tags
}

####################################################################
# Create EFS for FS sharing
####################################################################
resource "aws_efs_file_system" "efs" {
  creation_token = "${local.name}-efs"
  tags           = local.tags
}

resource "aws_efs_mount_target" "efs_target" {
  count           = length(module.vpc.azs)
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [module.efs_sg.security_group_id]
}

#####################################################################
# Get AWS AMI ID
#####################################################################
data "aws_ami" "amazon_linux" {
  #executable_users = ["self"]
  most_recent = true
  name_regex  = "^amzn2*"
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-kernel*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

####################################################################
# Create ELB
####################################################################
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "6.10.0"

  name               = "${local.name}-elb"
  load_balancer_type = "application"
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  security_groups    = [module.http_sg.security_group_id]
  internal           = false

  http_tcp_listeners = [
    {
      port               = "80"
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  target_groups = [
    {
      name_prefix      = "${local.name}-tg"
      backend_protocol = "HTTP"
      backend_port     = 80
      health_check = {
        enabled             = true
        interval            = 60
        path                = "/"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 10
        protocol            = "HTTP"
        matcher             = "200-399"
      }
    }
  ]

  tags = local.tags
}

####################################################################
# Generate SSH Key for EC2
####################################################################
resource "tls_private_key" "priv_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ssh_key" {
  key_name   = "${local.name}-key"
  public_key = tls_private_key.priv_key.public_key_openssh
}

####################################################################
# AutoSacling Group
####################################################################
module "wp-asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "6.3.0"

  name                      = "${local.name}-asg"
  instance_name             = "${local.name}-web"
  min_size                  = 1
  max_size                  = 2
  desired_capacity          = 1
  wait_for_capacity_timeout = 0
  health_check_type         = "ELB"
  vpc_zone_identifier       = module.vpc.public_subnets

  # Launch Template
  launch_template_name        = "${local.name}-lt"
  launch_template_description = "Wordpress Launch Template"
  update_default_version      = true
  image_id                    = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  target_group_arns           = module.alb.target_group_arns
  key_name                    = aws_key_pair.ssh_key.id
  user_data = base64encode(templatefile("${path.module}/wordpress-init.sh",
    {
      vars = {
        efs_dns_name = "${resource.aws_efs_file_system.efs.dns_name}"
      }
  }))
  tag_specifications = [
    {
      resource_type = "instance"
      tags          = local.tags
    }
  ]

  network_interfaces = [
    {
      delete_on_termination       = true
      description                 = "eth0"
      device_index                = 0
      security_groups             = [module.ssh_sg.security_group_id]
      associate_public_ip_address = true
    }
  ]

  scaling_policies = {
    scale-up = {
      policy_type        = "SimpleScaling"
      name               = "${local.name}-cpu-scale-up"
      scaling_adjustment = 1
      adjustment_type    = "ChangeInCapacity"
      cooldown           = "300"
    },
    scale-down = {
      policy_type        = "SimpleScaling"
      name               = "${local.name}-cpu-scale-down"
      scaling_adjustment = "-1"
      adjustment_type    = "ChangeInCapacity"
      cooldown           = "300"
    }
  }

  tags = local.tags

  depends_on = [resource.aws_efs_mount_target.efs_target]
}


#####################################################################
# CloudWatch Autoscale Metric
#####################################################################
resource "aws_cloudwatch_metric_alarm" "scale-up-cpu-alarm" {
  alarm_name          = "scale-up-cpu-alarm"
  alarm_description   = "CPU Alarm for ASG up scaling"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "50"
  dimensions = {
    "AutoScalingGroupName" = "${module.wp-asg.autoscaling_group_name}"
  }
  actions_enabled = true
  alarm_actions   = ["${module.wp-asg.autoscaling_policy_arns.scale-up}"]
  tags            = local.tags
}


resource "aws_cloudwatch_metric_alarm" "scale-down-cpu-alarm" {
  alarm_name          = "scale-down-cpu-alarm"
  alarm_description   = "CPU Alarm for ASG down scaling"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "10"
  dimensions = {
    "AutoScalingGroupName" = "${module.wp-asg.autoscaling_group_name}"
  }
  actions_enabled = true
  alarm_actions   = ["${module.wp-asg.autoscaling_policy_arns.scale-down}"]
  tags            = local.tags
}

##################################################################
# Creates RDS MySQL Instance
##################################################################
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "4.2.0"

  identifier = "${local.name}-db"

  # All available versions: http://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_MySQL.html#MySQL.Concepts.VersionMgmt
  engine                    = "mariadb"
  engine_version            = "10.6.7"
  create_db_parameter_group = "false"
  create_db_option_group    = "false"
  skip_final_snapshot       = "true"

  # All available instance classes: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.html
  instance_class        = "db.t3.micro"
  allocated_storage     = 5
  max_allocated_storage = 10

  username = "admin"
  db_name  = "wordpressdb"

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  multi_az               = "true"
  subnet_ids             = module.vpc.database_subnets
  vpc_security_group_ids = [module.db_sg.security_group_id]
  tags                   = local.tags
}

############################################################################
# Get EC2 Instance details
############################################################################

## Delay to allow time to initialize EC2
resource "time_sleep" "wait_180_seconds" {
  create_duration = "180s"
}

data "aws_instances" "wp-web" {
  instance_tags = local.tags

  filter {
    name   = "key-name"
    values = ["${local.name}-key"]
  }
  instance_state_names = ["running"]
  depends_on           = [module.wp-asg, resource.time_sleep.wait_180_seconds]
}


######################################################################
# Output
######################################################################
output "public_key_ec2" {
  value       = tls_private_key.priv_key.private_key_pem
  sensitive   = true
  description = "ec2-user Private Key for EC2 instance(s) in PEM format"
}

output "alb_dns_name" {
  value       = module.alb.lb_dns_name
  sensitive   = false
  description = "ALB DNS Name to connect frontend"
}

output "ec2_ssh_IP" {
  value       = data.aws_instances.wp-web.public_ips
  sensitive   = false
  description = "EC2 Pulic IP for SSH"
}

output "DB_Username" {
  value       = module.db.db_instance_username
  sensitive   = true
  description = "Database Username"
}

output "DB_Name" {
  value       = module.db.db_instance_name
  sensitive   = false
  description = "Database Name"
}

output "DB_Password" {
  value       = module.db.db_instance_password
  sensitive   = true
  description = "Database password"
}

output "DB_Connection_Name" {
  value       = module.db.db_instance_endpoint
  sensitive   = false
  description = "Database connection string"
}
