# Find the user currently in use by AWS
data "aws_caller_identity" "current" {}

# Region in which to deploy the solution
data "aws_region" "current" {}

# Availability zones to use in our solution
data "aws_availability_zones" "available" {
  state = "available"
}


# To Authenticate with ECR Public in eu-east-1
//data "aws_ecrpublic_authorization_token" "token" {
//  provider = aws.virginia
//}

data "aws_ecr_authorization_token" "token" {
  registry_id = data.aws_caller_identity.current.account_id
}

data "aws_partition" "current" {}