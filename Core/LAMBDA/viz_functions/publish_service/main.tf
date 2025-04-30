terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      configuration_aliases = [ aws.sns, aws.no_tags]
    }
  }
}

locals {
  viz_service_path = "${split("Core/", abspath(path.module))[1]}"
  egis_host = var.environment == "prod" ? "https://maps.water.noaa.gov/portal" : var.environment == "uat" ? "https://maps-staging.water.noaa.gov/portal" : var.environment == "ti" ? "https://maps-testing.water.noaa.gov/portal" : "https://hydrovis-dev.nwc.nws.noaa.gov/portal"
  service_suffix = var.environment == "prod" ? "" : var.environment == "uat" ? "_beta" : var.environment == "ti" ? "_alpha" : "_gamma"
}

data "archive_file" "deploy_zip" {
  type = "zip"
  source_dir = "${path.module}/deploy/code"
  output_path = "${path.module}/temp/${var.environment}_${var.region}_deploy.zip"
}

resource "aws_s3_object" "deploy_zip_upload" {
  provider = aws.no_tags  
  bucket      = var.deployment_bucket
  key         = "terraform_artifacts/${local.viz_service_path}/${var.environment}/deploy.zip"
  source      = data.archive_file.deploy_zip.output_path
  source_hash = filemd5(data.archive_file.deploy_zip.output_path)
}

resource "aws_lambda_function" "lambda" {
  function_name = "hv-vpp-${var.environment}-viz-publish-service"
  description   = "Lambda function to check and publish (if needed) an egis service based on a SD file in S3."
  memory_size   = 1024
  timeout       = 600
  vpc_config {
    security_group_ids = var.db_lambda_security_groups
    subnet_ids         = var.db_lambda_subnets
  }
  environment {
    variables = {
      GIS_PASSWORD        = var.egis_portal_password
      GIS_HOST            = local.egis_host
      GIS_USERNAME        = "hydrovis.proc"
      PUBLISH_FLAG_BUCKET = var.python_preprocessing_bucket
      S3_BUCKET           = var.viz_authoritative_bucket
      SD_S3_PATH          = "viz_sd_files/${var.environment}"
      MAPX_S3_PATH        = "viz_mapx_files/${var.environment}"
      SERVICE_TAG         = local.service_suffix
      EGIS_DB_HOST        = var.egis_db_host
      EGIS_DB_DATABASE    = var.egis_db_name
      EGIS_DB_USERNAME    = jsondecode(var.egis_db_user_secret_string)["username"]
      EGIS_DB_PASSWORD    = jsondecode(var.egis_db_user_secret_string)["password"]
      ENVIRONMENT         = var.environment
    }
  }
  s3_bucket        = aws_s3_object.deploy_zip_upload.bucket
  s3_key           = aws_s3_object.deploy_zip_upload.key
  source_code_hash = filebase64sha256(data.archive_file.deploy_zip.output_path)
  runtime          = "python3.9"
  handler          = "lambda_function.lambda_handler"
  role             = var.lambda_role
  layers = var.layers
  tags = {
    "Name" = "hv-vpp-${var.environment}-viz-publish-service"
  }
}