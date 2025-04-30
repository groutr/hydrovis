###########################################################
###########################################################
#####  START STATIC CONFIGURATION: DO NOT EDIT BELOW  #####
###########################################################
###########################################################
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.95"
    }
  }
}

locals {
  env = yamldecode(file("./configuration.yml"))
  region = "us-east-1"
  nwm_dataflow_version = "prod"
  tags = {
    "hydrovis-region": local.region
    "noaa:fismaid": "noaa8501"
    "noaa:lineoffice": "nws"
    "noaa:programoffice": "nws-dis"
    "noaa:projectid": "noaa8501"
    "noaa:taskorderid": "TBD"
    "noaa:environment": "dev"
    "noaa:applicationname": "hydrovis-vpp"
    "noaa:subcomponent": "hydrovis-vpp-other"
    "noaa:monitoring": "false"
    "experimental": "true"
  }
}

provider "aws" {
  profile = local.env.profile
  region = local.region
  shared_credentials_files = ["/cloud/aws/credentials"]
  default_tags {
    tags = merge(local.tags, {
      CreatedBy = "Terraform"
    })
  }
}

provider "aws" {
  alias                    = "sns"
  region                   = local.region
  profile                  = local.env.profile
  shared_credentials_files = ["/cloud/aws/credentials"]

  default_tags {
    tags = merge(local.tags, {
      CreatedBy = "Terraform"
    })
  }
}

provider "aws" {
  alias = "no_tags"
  region = local.region
  profile = local.env.profile
  shared_credentials_files = ["/cloud/aws/credentials"]
}

data "aws_resourcegroupstaggingapi_resources" "all" {
  tag_filter {
    key = "noaa:applicationname"
    values = ["hydrovis-vpp"]
  }
}

data "aws_lambda_function" "all" {
  for_each = tomap({ 
    for arn in data.aws_resourcegroupstaggingapi_resources.all.resource_tag_mapping_list[*].resource_arn: 
      split("hv-vpp-ti-", arn)[1] => split(":", arn)[length(split(":", arn)) - 1]
        if startswith(arn, "arn:aws:lambda:") && strcontains(arn, ":function:hv-vpp-ti-") 
  })
  function_name = each.value
}

data "aws_s3_bucket" "all" {
  for_each = tomap({ 
    for arn in data.aws_resourcegroupstaggingapi_resources.all.resource_tag_mapping_list[*].resource_arn: 
      split("-${local.region}", split(":aws:s3:::hydrovis-ti-", arn)[1])[0] => split(":", arn)[length(split(":", arn)) - 1] 
        if startswith(arn, "arn:aws:s3:::hydrovis-ti-") && endswith(arn, local.region)
  })
  bucket = each.value
}

data "aws_sfn_state_machine" "all" {
  for_each = tomap({ 
    for arn in data.aws_resourcegroupstaggingapi_resources.all.resource_tag_mapping_list[*].resource_arn: 
      split(":hv-vpp-ti-", arn)[1] => split(":", arn)[length(split(":", arn)) - 1] 
        if startswith(arn, "arn:aws:states:") && strcontains(arn, ":hv-vpp-ti-")
  })
  name = each.value
}

data "aws_iam_role" "viz_pipeline_role" {
  name = "hv-vpp-ti-${local.region}-viz-pipeline"
}

data "aws_cloudwatch_log_group" "all" {
  for_each = tomap({ 
    for arn in data.aws_resourcegroupstaggingapi_resources.all.resource_tag_mapping_list[*].resource_arn: 
      split(":hv-vpp-ti-${local.region}-", arn)[1] => split(":", arn)[length(split(":", arn)) - 1] 
        if startswith(arn, "arn:aws:logs:") && strcontains(arn, ":log-group:hv-vpp-ti-${local.region}-")
  })
  name = each.value
}

data "aws_secretsmanager_secret_version" "all" {
  for_each = tomap({ 
    for arn in data.aws_resourcegroupstaggingapi_resources.all.resource_tag_mapping_list[*].resource_arn: 
      join("-", slice(split("-", split(":hv-vpp-ti-", arn)[1]), 0, length(split("-", split(":hv-vpp-ti-", arn)[1])) - 1)) => arn
        if startswith(arn, "arn:aws:secretsmanager:") && strcontains(arn, ":secret:hv-vpp-ti-")
  })
  secret_id = each.value
}

module "custom-deploy" {
  source = "./custom_deploy"
  providers = {
    aws     = aws
    aws.sns = aws.sns
    aws.no_tags = aws.no_tags
  }

  viz_role = data.aws_iam_role.viz_pipeline_role.arn
  lambda_functions = data.aws_lambda_function.all
  step_functions = data.aws_sfn_state_machine.all
  s3_buckets = data.aws_s3_bucket.all
  cloudwatch_log_groups = data.aws_cloudwatch_log_group.all
  secrets = data.aws_secretsmanager_secret_version.all
  region = local.region
  deploy_resources = local.env.deploy_resources
  personal_tag = local.env.personal_tag
  profile = local.env.profile
  account_id = local.env.account_id
  default_tags = local.tags
  nwm_dataflow_version = local.nwm_dataflow_version
  hand_version = local.env.hand_version
  fim_version = local.env.fim_version
  egis_portal_password = local.env.egis_portal_password
}
#########################################################
#########################################################
#####  END STATIC CONFIGURATION: DO NOT EDIT ABOVE  #####
#########################################################
#########################################################