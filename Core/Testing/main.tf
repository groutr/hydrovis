terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      configuration_aliases = [ aws.sns, aws.no_tags]
    }
  }
}

variable "environment" {
  type = string
}

variable "s3_module" {
  type = any
}

variable "lambda_module" {
  type = any
}

variable "role" {
  type        = string
}
variable "deployment_bucket" {
  type        = string
}

locals {
  test_bucket = var.s3_module.buckets["deployment"].bucket
  init_pipeline_lambda = var.lambda_module.initialize_pipeline
}

resource "aws_cloudwatch_event_rule" "detect_test_files" {
  name                = "hv-vpp-${var.environment}-detect-test-files"
  description         = "Detects when a new test file has been created"
  event_pattern       = <<EOF
  {
    "source": ["aws.s3"],
    "detail-type": ["Object Created"],
    "detail": {
      "bucket": {
        "name": ["${local.test_bucket}"]
      },
      "object": {
        "key": [{
          "prefix": "common/data/model/com/nwm/prod/nwm."
        }]
      }
    }
  }
  EOF
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_initialize_pipeline" {
  statement_id  = "AllowExecutionFromCloudWatchForTesting"
  action        = "lambda:InvokeFunction"
  function_name = local.init_pipeline_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.detect_test_files.arn
}

resource "aws_cloudwatch_event_target" "trigger_pipeline_test_run" {
  rule      = aws_cloudwatch_event_rule.detect_test_files.name
  target_id = local.init_pipeline_lambda.function_name
  arn       = local.init_pipeline_lambda.arn
  input_transformer {
    input_paths = {
      "s3_bucket": "$.detail.bucket.name",
      "s3_key": "$.detail.object.key"
    }
    input_template = <<EOF
    {
      "Records": [
        {
          "Sns": {
            "TopicArn": "N/A",
            "Message": "{\"Records\": [{\"s3\": {\"bucket\": {\"name\": \"<s3_bucket>\"}, \"object\": {\"key\": \"<s3_key>\"}}}]}"
          }
        }
      ]
    }
    EOF
  }
}

resource "aws_sfn_state_machine" "trigger_apocalyptic_tests_step_function" {
  name     = "hv-vpp-${var.environment}-trigger-apocalyptic-tests"
  role_arn = var.role

  definition = templatefile("${path.module}/trigger_apocalyptic_tests.json.tftpl", {
    deployment_bucket = var.deployment_bucket
  })
}