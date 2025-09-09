################################################################################
# Security Configurations
################################################################################

# IMDSv2 Account Default
resource "aws_ec2_instance_metadata_defaults" "imdsv2_default" {
  http_tokens                 = "required"
  http_put_response_hop_limit = 2
  http_endpoint               = "enabled"
  instance_metadata_tags      = "disabled"
}

# SSM IAM Role for EC2 instances (if needed for standalone EC2s)
resource "aws_iam_role" "ec2_ssm_role" {
  name = "${local.name}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

# Attach SSM policy to EC2 role
resource "aws_iam_role_policy_attachment" "ec2_ssm_policy" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile for EC2 instances
resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "${local.name}-ec2-ssm-profile"
  role = aws_iam_role.ec2_ssm_role.name

  tags = local.tags
}

# Launch template with security configurations
resource "aws_launch_template" "secure_template" {
  name_prefix   = "${local.name}-secure-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  # Security: IMDSv2 required
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags = "disabled"
  }

  # Security: SSM instance profile
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_ssm_profile.name
  }

  # User data to ensure SSM agent is running
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y amazon-ssm-agent
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name = "${local.name}-secure-instance"
    })
  }

  tags = local.tags
}
