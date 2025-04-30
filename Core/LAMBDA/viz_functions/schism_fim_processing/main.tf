terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      configuration_aliases = [aws.no_tags]
    }
  }
}

locals {
  viz_schism_fim_resource_name = "hv-vpp-${var.environment}-viz-schism-fim-processing"
  viz_service_path = "${split("Core/", abspath(path.module))[1]}"
}


##################################
## SCHISM HUC PROCESSING LAMBDA ##
##################################

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
    content  = sensitive(file("${path.module}/../../layers/viz_lambda_shared_funcs/python/viz_classes.py"))
    filename = "code/viz_classes.py"
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
  name                 = local.viz_schism_fim_resource_name
  image_tag_mutability = "MUTABLE"

  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_codebuild_project" "codebuild" {
  name          = local.viz_schism_fim_resource_name
  description   = "Codebuild project that builds the lambda container based on a zip file with lambda code and dockerfile. Also deploys a lambda function using the ECR image"
  build_timeout = "60"
  service_role  = var.codebuild_role

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"
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
    type            = "S3"
    location        = "${aws_s3_object.deploy_zip_upload.bucket}/${aws_s3_object.deploy_zip_upload.key}"
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

data "aws_iam_policy_document" "batch_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "aws_batch_service_role" {
  name               = "aws_batch_service_role"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_iam_role_policy_attachment" "aws_batch_service_role" {
  role       = aws_iam_role.aws_batch_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}


resource "aws_iam_role" "schism_execution" {
  name = "hv-vpp-${var.environment}-${var.region}-schism-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = [
            "ecs-tasks.amazonaws.com",
            "ec2.amazonaws.com"
          ]
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "schism_execution" {
  name = "hv-vpp-${var.environment}-${var.region}-schism-execution"
  role = aws_iam_role.schism_execution.name
}

resource "aws_iam_role_policy" "schism_execution" {
  name   = "hv-vpp-${var.environment}-${var.region}-schism_execution"
  role   = aws_iam_role.schism_execution.id
  policy = file("${path.module}/schism_execution.json")
}

resource "aws_iam_role_policy_attachment" "schism_execution_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.schism_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
resource "aws_iam_role_policy_attachment" "schism_execution_AmazonEC2ContainerServiceforEC2Role" {
  role       = aws_iam_role.schism_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}
resource "aws_iam_role_policy_attachment" "schism_execution_AmazonECSTaskExecutionRolePolicy" {
  role       = aws_iam_role.schism_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role_policy_attachment" "schism_execution_AmazonRDSFullAccess" {
  role       = aws_iam_role.schism_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"
}
resource "aws_iam_role_policy_attachment" "schism_execution_AmazonS3FullAccess" {
  role       = aws_iam_role.schism_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}
resource "aws_iam_role_policy_attachment" "schism_execution_AWSBatchFullAccess" {
  role       = aws_iam_role.schism_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBatchFullAccess"
}
resource "aws_iam_role_policy_attachment" "schism_execution_AWSBatchServiceRole" {
  role       = aws_iam_role.schism_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

resource "aws_batch_compute_environment" "schism_fim_compute_env" {
  compute_environment_name = "hv-vpp-${var.environment}-schism-fim-compute-env"

  compute_resources {
    instance_role = aws_iam_instance_profile.schism_execution.arn

    instance_type = [
      "r7g.4xlarge",
    ]

    min_vcpus = 0
    max_vcpus = 112

    security_group_ids = var.security_groups

    subnets = var.subnets

    type = "EC2"
  }

  service_role = aws_iam_role.aws_batch_service_role.arn
  type         = "MANAGED"
  depends_on   = [aws_iam_role_policy_attachment.aws_batch_service_role]  # Not sure on this...
}

resource "aws_batch_job_queue" "schism_fim_job_queue" {
  name     = "hv-vpp-${var.environment}-schism-fim-job-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order = 1
    compute_environment = aws_batch_compute_environment.schism_fim_compute_env.arn
  }
}

resource "aws_batch_job_definition" "schism_fim_job_definition" {
  name = "hv-vpp-${var.environment}-schism-fim-job-definition"
  type = "container"
  container_properties = jsonencode({
    command = ["python3", "./process_schism_fim.py", "Ref::args_as_json"],
    image   = "${var.account_id}.dkr.ecr.${var.region}.amazonaws.com/${local.viz_schism_fim_resource_name}:${var.ecr_repository_image_tag}"

    resourceRequirements = [
      {
        type  = "VCPU"
        value = "1"
      },
      {
        type  = "MEMORY"
        value = "7000"
      }
    ]

    environment = [
      {
        name  = "INPUTS_BUCKET"
        value = var.deployment_bucket
      },
      {
        name  = "INPUTS_PREFIX"
        value = "schism_fim"
      },
      {
        name  = "VIZ_DB_DATABASE"
        value = var.viz_db_name
      },
      {
        name  = "VIZ_DB_HOST"
        value = var.viz_db_host
      },
      {
        name  = "VIZ_DB_PASSWORD"
        value = jsondecode(var.viz_db_user_secret_string)["password"]
      },
      {
        name  = "VIZ_DB_USERNAME"
        value = jsondecode(var.viz_db_user_secret_string)["username"]
      }
    ]
  })
}