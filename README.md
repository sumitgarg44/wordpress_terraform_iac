# About
Code helps to deploy highly available autoscaled Wordpress stack on AWS Public Cloug using Terraform with following components:

* VPC with public, private and database subnets.
* Security groups
* EFS - Elastic Filesystem (for sharing between EC2 instances)
* MariaDB RDS multi-AZ instance
* Application Load balancer (ALB)
* AutoSacling Group with Launch template

# Prerequisites
* AWS cli credentials
* Terraform ( Installation instructions at https://learn.hashicorp.com/tutorials/terraform/install-cli )

# Default Values
Following are the default values coded. Adjust them according to need before execution.

Name  | Value
------------- | -------------
AWS Region  | eu-west-1
Name prefix  | wp
Environment | dev
CMS | wordpress
VPC cidr | 10.0.0.0/16
Public subnets | 10.0.1.0/24, 10.0.2.0/24
Private subnets | 10.0.3.0/24, 10.0.4.0/24
Database subnets | 10.0.5.0/24, 10.0.6.0/24
AMI | Latest image of Amazon Linux 2
Target Group healthy threshold | 3
Target Group unhealthy threshold | 3
Target Group interval | 60
ASG Min Size | 1
ASG Max Size | 2
ASG Desired Capacity | 1
Scale down CPU utilization | Less than 10%
Scale up CPU utilization | Greater than 50%
MariaDB Version | 10.6.7
RDS allocated storage | 5GB
RDS Max allocated storage | 10GB

# Usage
* Clone the git repository
* Change directory to wordpress_terraform_iac
* Install require providers using 'terraform init'
* Create stack using 'terraform apply'

# Post Deploy
After successful deploy, following commands can be used to fetch sensitive information to complete Wordpress installation.
* EC2 Private key for SSH 'terraform output public_key_ec2'
* Database username 'terraform output DB_Username'
* Database password 'terraform output DB_Password'
