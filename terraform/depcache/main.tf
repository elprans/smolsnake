# Copyright Contributors to the smolsnake project.
#
# SPDX-License-Identifier: 0BSD


data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  region        = data.aws_region.current.name
  smolsnake_rev = "main"
}


resource "aws_efs_file_system" "deps" {
  tags = {
    Name = "smolsnake-deps"
  }
}

resource "aws_efs_access_point" "deps" {
  file_system_id = aws_efs_file_system.deps.id
}

resource "aws_sqs_queue" "cache_request_queue" {
  name = "smolsnake-cache-request-queue"
}

resource "aws_sqs_queue" "cache_response_queue" {
  name = "smolsnake-cache-response-queue"
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    effect = "Allow"
  }
}

resource "aws_iam_role" "efs_writer" {
  name               = "smolsnake-datasync-efs-writer"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "efs_access_policy" {
  statement {
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:ClientRootAccess"
    ]

    resources = [
      aws_efs_file_system.deps.arn,
    ]

    # condition {
    #   test     = "Bool"
    #   variable = "aws:SecureTransport"

    #   values = [
    #     "true"
    #   ]
    # }

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"

      values = [
        aws_efs_access_point.deps.arn
      ]
    }

    effect = "Allow"
  }

  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
    ]

    resources = [
      aws_sqs_queue.cache_request_queue.arn,
    ]

    effect = "Allow"
  }

  statement {
    actions = [
      "sqs:SendMessage",
    ]

    resources = [
      aws_sqs_queue.cache_response_queue.arn,
    ]

    effect = "Allow"
  }
}

resource "aws_iam_policy" "efs_access_policy" {
  name   = "smolsnake-datasync-efs-destination-policy"
  policy = data.aws_iam_policy_document.efs_access_policy.json
}

resource "aws_iam_role_policy_attachment" "efs_access_policy" {
  role       = aws_iam_role.efs_writer.name
  policy_arn = aws_iam_policy.efs_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "efs_writer_can_ssm" {
  role       = aws_iam_role.efs_writer.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "efs_read_access_policy" {
  statement {
    actions = [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:DescribeMountTargets",
    ]

    resources = [
      aws_efs_file_system.deps.arn,
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"

      values = [
        "true"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "elasticfilesystem:AccessPointArn"

      values = [
        aws_efs_access_point.deps.arn
      ]
    }

    effect = "Allow"
  }
}

resource "aws_iam_policy" "efs_read_access_policy" {
  name   = "smolsnake-efs-read-policy"
  policy = data.aws_iam_policy_document.efs_read_access_policy.json
}

resource "aws_vpc" "smolsnake" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "smolsnake" {
  vpc_id            = aws_vpc.smolsnake.id
  availability_zone = "${local.region}a"
  cidr_block        = "10.0.1.0/24"

  map_public_ip_on_launch                     = true
  enable_resource_name_dns_a_record_on_launch = true
  private_dns_hostname_type_on_launch         = "resource-name"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.smolsnake.id

  tags = {
    Name = "smolsnake-igw"
  }
}

resource "aws_route" "internet_ipv4_access" {
  route_table_id         = aws_vpc.smolsnake.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_security_group" "efs_writer_instance" {
  name        = "smolsnake-efs-writer-sg"
  description = "Security group for smolsnake EFS writer instance"
  vpc_id      = aws_vpc.smolsnake.id
  tags = {
    Name = "smolsnake-efs-writer-sg"
  }
}

# SSH traffic into the EFS writer instance (for debug)
resource "aws_vpc_security_group_ingress_rule" "ssh_in" {
  security_group_id = aws_security_group.efs_writer_instance.id
  count             = var.enable_ssh ? 1 : 0

  description = "SSH in"
  from_port   = 22
  to_port     = 22
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
}

# Internet traffic out of the EFS writer instance (for SSM and package setup)
resource "aws_vpc_security_group_egress_rule" "tcp_out" {
  security_group_id = aws_security_group.efs_writer_instance.id

  from_port   = -1
  to_port     = -1
  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

resource "aws_security_group" "efs_mount_target" {
  name        = "smolsnake-efs-mount-target-sg"
  description = "Security group for smolsnake EFS mount target"
  vpc_id      = aws_vpc.smolsnake.id
  tags = {
    Name = "smolsnake-efs-mount-target-sg"
  }
}

resource "aws_security_group" "efs_reader" {
  name        = "smolsnake-efs-reader-sg"
  description = "Security group for smolsnake EFS readers (lambdas)"
  vpc_id      = aws_vpc.smolsnake.id
  tags = {
    Name = "smolsnake-efs-reader-sg"
  }
}

# NFS requests from EFS writer instance
resource "aws_vpc_security_group_ingress_rule" "efs_in_from_writers" {
  security_group_id            = aws_security_group.efs_mount_target.id
  referenced_security_group_id = aws_security_group.efs_writer_instance.id

  description = "EFS in"
  from_port   = 2049
  to_port     = 2049
  ip_protocol = "tcp"
}

# NFS requests from EFS readers (lambdas)
resource "aws_vpc_security_group_ingress_rule" "efs_in_from_readers" {
  security_group_id            = aws_security_group.efs_mount_target.id
  referenced_security_group_id = aws_security_group.efs_reader.id

  description = "EFS in"
  from_port   = 2049
  to_port     = 2049
  ip_protocol = "tcp"
}

# NFS
resource "aws_vpc_security_group_egress_rule" "efs_out_from_readers" {
  security_group_id            = aws_security_group.efs_reader.id
  referenced_security_group_id = aws_security_group.efs_mount_target.id

  from_port   = 2049
  to_port     = 2049
  ip_protocol = "tcp"
}

resource "aws_efs_mount_target" "deps" {
  file_system_id = aws_efs_file_system.deps.id
  subnet_id      = aws_subnet.smolsnake.id
  security_groups = [
    aws_security_group.efs_mount_target.id
  ]
}

data "aws_ami" "base" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-minimal*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "image-type"
    values = ["machine"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "hypervisor"
    values = ["xen"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_iam_instance_profile" "efs_writer" {
  name = "smolsnake_efs_writer"
  path = "/smolsnake/"
  role = aws_iam_role.efs_writer.name
}

resource "aws_launch_template" "efs_writer" {
  name          = "smolsnake-efs-writer-template"
  image_id      = data.aws_ami.base.image_id
  instance_type = "t3a.medium"

  network_interfaces {
    subnet_id       = aws_subnet.smolsnake.id
    security_groups = [aws_security_group.efs_writer_instance.id]
  }

  iam_instance_profile {
    arn = aws_iam_instance_profile.efs_writer.arn
  }

  maintenance_options {
    auto_recovery = "default"
  }
}

locals {
  ssh_keys = var.enable_ssh ? {
    for filename in fileset("${path.module}/ssh_authorized_keys", "*.pub") :
    split(".", filename)[0] => file("${path.module}/ssh_authorized_keys/${filename}")
  } : {}
}

resource "aws_instance" "efs_writer" {
  launch_template {
    id      = aws_launch_template.efs_writer.id
    version = aws_launch_template.efs_writer.latest_version
  }

  source_dest_check           = false
  user_data_replace_on_change = true
  user_data_base64 = base64gzip(templatefile(
    "${path.module}/efs-writer-cloud-init.yaml.tftpl", {
      region                 = local.region
      ssh_keys               = values(local.ssh_keys)
      file_system_id         = aws_efs_file_system.deps.id
      access_point_id        = aws_efs_access_point.deps.id
      sqsincoming            = file("${path.module}/sqsincoming.py")
      sqs_request_queue_url  = aws_sqs_queue.cache_request_queue.url
      sqs_response_queue_url = aws_sqs_queue.cache_response_queue.url
      smolsnake_rev          = local.smolsnake_rev
    }
  ))

  root_block_device {
    volume_size = 10
  }

  tags = {
    Name = "smolsnake-efs-writer"
  }
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    effect = "Allow"
  }
}

resource "aws_iam_role" "lambda" {
  name               = "smolsnake-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "efs_read_access_policy" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.efs_read_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

output "cache_queues" {
  value = {
    request  = aws_sqs_queue.cache_request_queue.url
    response = aws_sqs_queue.cache_response_queue.url
  }
}

output "roles" {
  value = {
    lambda = aws_iam_role.lambda.arn
  }
}

output "efs" {
  value = {
    access_point_arn = aws_efs_access_point.deps.arn
  }
}

output "net" {
  value = {
    subnet_ids         = [aws_subnet.smolsnake.id]
    security_group_ids = [aws_security_group.efs_reader.id]
  }
}

output "depcache_server" {
  value = {
    ip = aws_instance.efs_writer.public_ip
  }
}

output "region" {
  value = local.region
}
