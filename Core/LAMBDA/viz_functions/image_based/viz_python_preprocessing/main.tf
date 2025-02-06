terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.84.0"
    }
  }
}

provider "aws" {
  region                   = var.region
  profile                  = var.environment
  default_tags {
    tags = merge(var.default_tags, {
      CreatedBy = "Terraform"
    })
  }
}

locals {
  viz_service_name = "viz-python-preprocessing"
  viz_lambda_name = "hv-vpp-${var.environment}-${local.viz_service_name}"
  viz_service_path = "${split("Core/", abspath(path.module))[1]}"
}


data "archive_file" "viz_service_zip" {
  type = "zip"
  output_path = "${path.module}/temp/${local.viz_service_name}_${var.environment}_${var.region}.zip"

  dynamic "source" {
    for_each = fileset("${path.module}/deploy", "**")
    content {
      content  = file("${path.module}/deploy/${source.key}")
      filename = source.key
    }
  }

  source {
    content  = file("${path.module}/../../../layers/viz_lambda_shared_funcs/python/viz_lambda_shared_funcs.py")
    filename = "code/viz_lambda_shared_funcs.py"
  }

  source {
    content  = file("${path.module}/../../../layers/viz_lambda_shared_funcs/python/viz_classes.py")
    filename = "code/viz_classes.py"
  }
  source {
    content = file("${path.module}/buildspec.yml")
    filename = "buildspec.yml"
  }

  source {
    content = templatefile("${path.module}/serverless.yml.tmpl", {
      SERVICE_NAME = replace(local.viz_lambda_name, "_", "-")
      LAMBDA_TAGS = jsonencode(merge(var.default_tags, { Name = local.viz_lambda_name }))
      DEPLOYMENT_BUCKET = var.deployment_bucket
      AWS_DEFAULT_REGION = var.region
      LAMBDA_NAME = local.viz_lambda_name
      AWS_ACCOUNT_ID = var.account_id
      IMAGE_REPO_NAME = aws_ecr_repository.viz_image.name
      IMAGE_TAG = var.ecr_repository_image_tag
      LAMBDA_ROLE_ARN = var.lambda_role
      VIZ_DB_DATABASE = var.viz_db_name
      VIZ_DB_HOST = var.viz_db_host
      VIZ_DB_USERNAME = jsondecode(var.viz_db_user_secret_string)["username"]
      VIZ_DB_PASSWORD = jsondecode(var.viz_db_user_secret_string)["password"]
      AUTH_DATA_BUCKET = var.viz_authoritative_bucket
      SECURITY_GROUP_1   = var.security_groups[0]
      SUBNET_1           = var.subnets[0]
      SUBNET_2           = var.subnets[1]
    })
    filename = "serverless.yml"
  }
}

resource "aws_s3_object" "viz_service_zip_upload" {
  #provider = aws.no_tags  
  bucket      = var.deployment_bucket
  key         = "terraform_artifacts/${local.viz_service_path}/${var.environment}/deploy.zip"
  source      = data.archive_file.viz_service_zip.output_path
  source_hash = data.archive_file.viz_service_zip.output_md5
}

resource "aws_ecr_repository" "viz_image" {
  name                 = local.viz_lambda_name
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_codebuild_project" "viz_codebuild" {
  name          = local.viz_lambda_name
  description   = "Codebuild project that builds the lambda container based on a zip file with lambda code and dockerfile. Also deploys a lambda function using the ECR image"
  build_timeout = "60"
  service_role  = var.lambda_role

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:6.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = var.account_id
    }

    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.viz_image.name
    }

    environment_variable {
      name  = "IMAGE_TAG"
      value = var.ecr_repository_image_tag
    }
  }

  source {
    type     = "S3"
    location = "${aws_s3_object.viz_service_zip_upload.bucket}/${aws_s3_object.viz_service_zip_upload.key}"
  }
}

resource "null_resource" "viz_start_build" {
  triggers = {
    source_hash = data.archive_file.viz_service_zip.output_md5
    source_location = aws_s3_object.viz_service_zip_upload.key
  }

  #depends_on = [ 
  #  aws_s3_object.viz_service_zip_upload,
  #  aws_codebuild_project.viz_codebuild
  # ]

  provisioner "local-exec" {
    command = "aws codebuild start-build --project-name ${aws_codebuild_project.viz_codebuild.name} --profile ${var.environment} --region ${var.region}"
  }
}

resource "time_sleep" "wait_for_viz_build_finish" {
  triggers = {
    function_update = null_resource.viz_start_build.triggers.source_hash
  }
  depends_on = [null_resource.viz_start_build]

  create_duration = "180s"
}

data "aws_lambda_function" "viz_lambda_function" {
  function_name = aws_codebuild_project.viz_codebuild.name

  depends_on = [
    time_sleep.wait_for_viz_build_finish
  ]
}