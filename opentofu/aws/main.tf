terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # When these are null (the default) the AWS provider falls back to the
  # standard credential chain: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
  # AWS_SESSION_TOKEN env vars, shared config/credentials files, SSO, instance
  # profiles, etc. Prefer that over hardcoding secrets.
  access_key = var.access_key
  secret_key = var.secret_key
  token      = var.token
}

data "aws_vpc" "vpc" {
  id = var.vpc_id
}

resource "aws_subnet" "dualStack-subnet" {
  vpc_id                  = data.aws_vpc.vpc.id
  cidr_block              = cidrsubnet(data.aws_vpc.vpc.cidr_block, 4, 4)
  map_public_ip_on_launch = true

  ipv6_cidr_block                 = cidrsubnet(data.aws_vpc.vpc.ipv6_cidr_block, 8, 1)
  assign_ipv6_address_on_creation = true

  tags = {
    Name = "tfz-dualStack-subnet"
  }
}

resource "aws_security_group" "tfz_allow_k8s" {
  name        = "tfz_allow_k8s"
  description = "Allow K8s communications"
  vpc_id      = data.aws_vpc.vpc.id

  ingress {
    description      = "SSH from VPC"
    to_port          = 22
    from_port        = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "HTTP from VPC"
    to_port          = 80
    from_port        = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "HTTPS from VPC"
    to_port          = 443
    from_port        = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description = "All traffic"
    to_port     = 0
    from_port   = 0
    protocol    = "-1"
    cidr_blocks = [aws_subnet.dualStack-subnet.cidr_block]
  }

  tags = {
    Name = "tfz_allow_k8s"
  }
}

resource "aws_instance" "myInstance" {
  # One instance per cloud-init script provided; the count is derived from the
  # length of var.cloud_init_files (replaces the old %COUNT% placeholder).
  count = length(var.cloud_init_files)

  ami           = "ami-03fd334507439f4d1"
  instance_type = "t3.large"

  subnet_id = aws_subnet.dualStack-subnet.id

  key_name = "tferrandiz-key"

  vpc_security_group_ids = [aws_security_group.tfz_allow_k8s.id]

  root_block_device {
    volume_size = 20
    volume_type = "standard"
  }

  # Replaces the old %CLOUDINIT% placeholder.
  user_data = filebase64(var.cloud_init_files[count.index])

  tags = {
    Name = "tofu-tfz-vm${count.index}"
  }
}

output "subnet_id" {
  value = aws_subnet.dualStack-subnet.id
}

output "publicIP" {
  value = aws_instance.myInstance[*].public_ip
}
