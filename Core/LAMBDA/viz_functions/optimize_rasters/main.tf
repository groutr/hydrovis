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
}

data "archive_file" "deploy_zip" {
  type = "zip"
  output_path = "${path.module}/temp/${var.environment}_${var.region}_deploy.zip"

  dynamic "source" {
    for_each = fileset("${path.module}/deploy", "**")
    content {
      content  = sensitive(file("${path.module}/deploy/${source.key}"))
      filename = source.key
    }
  }

  source {
    content = templatefile("${path.module}/serverless.yml.tmpl", {
      SERVICE_NAME       = replace(var.lambda_name, "_", "-")
      LAMBDA_TAGS        = jsonencode(merge(var.default_tags, { Name = var.lambda_name }))
      DEPLOYMENT_BUCKET  = var.deployment_bucket
      AWS_DEFAULT_REGION = var.region
      LAMBDA_NAME        = var.lambda_name
      AWS_ACCOUNT_ID     = var.account_id
      IMAGE_REPO_NAME    = aws_ecr_repository.image.name
      IMAGE_TAG          = var.ecr_repository_image_tag
      LAMBDA_ROLE_ARN    = var.lambda_role
    })
    filename = "serverless.yml"
  }
}

resource "aws_s3_object" "deploy_zip_upload" {
  provider    = aws.no_tags  
  bucket      = var.deployment_bucket
  key         = "terraform_artifacts/${local.viz_service_path}/${var.environment}/deploy.zip"
  source      = data.archive_file.deploy_zip.output_path
  source_hash = data.archive_file.deploy_zip.output_md5
}

resource "aws_ecr_repository" "image" {
  name                 = var.lambda_name
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_codebuild_project" "codebuild" {
  name          = var.lambda_name
  description   = "Codebuild project that builds the lambda container based on a zip file with lambda code and dockerfile. Also deploys a lambda function using the ECR image"
  build_timeout = "60"
  service_role  = var.lambda_role

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    type                        = "ARM_CONTAINER"
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
      value = aws_ecr_repository.image.name
    }

    environment_variable {
      name  = "IMAGE_TAG"
      value = var.ecr_repository_image_tag
    }
  }

  source {
    type     = "S3"
    location = "${aws_s3_object.deploy_zip_upload.bucket}/${aws_s3_object.deploy_zip_upload.key}"
  }
}

resource "aws_lambda_invocation" "execute_codebuild" {
  function_name = var.execute_codebuild_function_name

  triggers = {
    function_update = data.archive_file.deploy_zip.output_md5
  }

  input = jsonencode({
    project_name = resource.aws_codebuild_project.codebuild.name
  })
}

data "aws_lambda_function" "lambda" {
  function_name = var.lambda_name

  depends_on = [
    resource.aws_lambda_invocation.execute_codebuild
  ]
}