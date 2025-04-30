terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      configuration_aliases = [ aws.sns, aws.no_tags]
    }
  }
}

########################################################################################################################################
########################################################################################################################################

locals {
  ecr_repository_image_tag = "latest"
  prodlike_environments = ["uat", "prod"]
  official_environments = concat(local.prodlike_environments, ["ti"])
  optimize_rasters = "optimize-rasters"
  hand_fim_processing = "hand-fim-processing"
  schism_fim_processing = "schism-fim-processing"
  raster_processing = "raster-processing"
  db_ingest = "db-ingest"
  egis_health_checker = "egis-health-checker"
  initialize_pipeline = "initialize-pipeline"
  db_postprocess_sql = "db-postprocess-sql"
  fim_data_prep = "fim-data-prep"
  publish_service = "publish-service"
  test_wrds_db = "test-wrds-db"
  update_egis_data = "update-egis-data"
  python_preprocessing = "python-preprocessing"
  execute_codebuild = "execute-codebuild"
}

###############
## DB Ingest ##
###############
module "db-ingest" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.db_ingest, false) ? 1 : 0
  source = "./db_ingest"
  providers = {
    aws = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  account_id = var.account_id
  region = var.region
  ecr_repository_image_tag = local.ecr_repository_image_tag
  lambda_role = var.lambda_role
  security_groups = var.db_lambda_security_groups
  subnets = var.db_lambda_subnets
  deployment_bucket = var.deployment_bucket
  viz_db_name = var.viz_db_name
  viz_db_host = var.viz_db_host
  viz_db_user_secret_string = var.viz_db_user_secret_string
  default_tags = var.default_tags
  profile = var.profile
  execute_codebuild_function_name = var.execute_codebuild_function_name_override != null ? var.execute_codebuild_function_name_override : module.execute-codebuild[0].lambda.function_name
}

resource "aws_lambda_function_event_invoke_config" "viz_db_ingest_destinations" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  function_name          = module.db-ingest[0].lambda.function_name
  maximum_retry_attempts = 0
  destination_config {
    on_failure {
      destination = var.email_sns_topics["viz_lambda_errors"].arn
    }
  }
}

#############################
##   DB Postprocess SQL    ##
#############################
module "db-postprocess-sql" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.db_postprocess_sql, false) ? 1 : 0
  source = "./db_postprocess_sql"
  providers = {
    aws     = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  region = var.region
  deployment_bucket = var.deployment_bucket
  fim_version = var.fim_version
  hand_version = var.hand_version
  lambda_role = var.lambda_role
  db_lambda_security_groups = var.db_lambda_security_groups
  db_lambda_subnets = var.db_lambda_subnets
  viz_db_host = var.viz_db_host
  viz_db_name = var.viz_db_name
  viz_db_user_secret_string = var.viz_db_user_secret_string
  layers = [
    var.psycopg2_sqlalchemy_layer,
    var.viz_lambda_shared_funcs_layer
  ]
}

resource "aws_lambda_function_event_invoke_config" "viz_db_postprocess_sql_destinations" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  function_name          = module.db-postprocess-sql[0].lambda.function_name
  maximum_retry_attempts = 0
  destination_config {
    on_failure {
      destination = var.email_sns_topics["viz_lambda_errors"].arn
    }
  }
}

##################################
## EGIS Health Checker Function ##
##################################
module "egis-health-checker" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.egis_health_checker, false) ? 1 : 0
  source = "./egis_health_checker"
  providers = {
    aws     = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  region = var.region
  deployment_bucket = var.deployment_bucket
  lambda_role = var.lambda_role
  db_lambda_security_groups = var.db_lambda_security_groups
  db_lambda_subnets = var.db_lambda_subnets
  pandas_layer  = var.pandas_layer
  requests_layer = var.requests_layer
}

resource "aws_cloudwatch_event_target" "check_lambda_every_five_minutes_egis_health_checker" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  rule      = var.five_minute_trigger.name
  target_id = module.egis-health-checker[0].lambda.function_name
  arn       = module.egis-health-checker[0].lambda.arn
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_check_lambda_egis_health_checker" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = module.egis-health-checker[0].lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.five_minute_trigger.arn
}

resource "aws_lambda_function_event_invoke_config" "egis_health_checker" {
  count = contains(local.prodlike_environments, var.environment) ? 1 : 0
  function_name          = module.egis-health-checker[0].lambda.function_name
  maximum_retry_attempts = 0
  destination_config {
    on_failure {
      destination = var.email_sns_topics["egis_healthcheck_errors"].arn
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "egis_healthcheck_errors" {
  count = contains(local.prodlike_environments, var.environment) ? 1 : 0
  alarm_name                = "${var.environment}_egis_healthcheck"
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  datapoints_to_alarm       = 1
  evaluation_periods        = 1

  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 600
  statistic           = "Sum"
  threshold           = 2
  treat_missing_data   = "notBreaching"

  dimensions = {
    FunctionName = module.egis-health-checker[0].lambda.function_name
  }
}

###########################
##   Execute Codebuild   ##
###########################
module "execute-codebuild" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.execute_codebuild, false) ? 1 : 0
  source = "./execute_codebuild"
  providers = {
    aws     = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  region = var.region
  deployment_bucket = var.deployment_bucket
  viz_role = var.lambda_role
  db_lambda_security_groups = var.db_lambda_security_groups
  db_lambda_subnets = var.db_lambda_subnets
}

#############################
##      FIM Data Prep      ##
#############################
module "fim-data-prep" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.fim_data_prep, false) ? 1 : 0
  source = "./fim_data_prep"
  providers = {
    aws     = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  region = var.region
  deployment_bucket = var.deployment_bucket
  fim_output_bucket = var.fim_output_bucket
  lambda_role = var.lambda_role
  db_lambda_security_groups = var.db_lambda_security_groups
  db_lambda_subnets = var.db_lambda_subnets
  viz_db_host = var.viz_db_host
  viz_db_name = var.viz_db_name
  viz_db_user_secret_string = var.viz_db_user_secret_string
  egis_db_host = var.egis_db_host
  egis_db_name = var.egis_db_name
  egis_db_user_secret_string = var.egis_db_user_secret_string
  fim_version = var.fim_version
  layers = [
    var.psycopg2_sqlalchemy_layer,
    var.xarray_layer,
    var.es_logging_layer,
    var.viz_lambda_shared_funcs_layer
  ]
}

resource "aws_lambda_function_event_invoke_config" "viz_fim_data_prep_destinations" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  function_name          = module.fim-data-prep[0].lambda.function_name
  maximum_retry_attempts = 0
  destination_config {
    on_failure {
      destination = var.email_sns_topics["viz_lambda_errors"].arn
    }
  }
}

############################
# HAND FIM processing
############################
module "hand-fim-processing" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.hand_fim_processing, false) ? 1 : 0
  source = "./hand_fim_processing"
  providers = {
    aws = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  account_id = var.account_id
  region = var.region
  ecr_repository_image_tag = local.ecr_repository_image_tag
  lambda_role = var.lambda_role
  security_groups = var.db_lambda_security_groups
  subnets = var.db_lambda_subnets
  deployment_bucket = var.deployment_bucket
  viz_db_name = var.viz_db_name
  viz_db_host = var.viz_db_host
  viz_db_user_secret_string = var.viz_db_user_secret_string
  egis_db_host = var.egis_db_host
  egis_db_name = var.egis_db_name
  egis_db_user_secret_string = var.egis_db_user_secret_string
  viz_authoritative_bucket = var.viz_authoritative_bucket
  default_tags = var.default_tags
  hand_version = var.hand_version
  fim_version = var.fim_version
  fim_data_bucket = var.fim_data_bucket
  profile = var.profile
  execute_codebuild_function_name = var.execute_codebuild_function_name_override != null ? var.execute_codebuild_function_name_override : module.execute-codebuild[0].lambda.function_name
}

#############################
##   Initialize Pipeline   ##
#############################
module "initialize-pipeline" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.initialize_pipeline, false) ? 1 : 0
  source = "./initialize_pipeline"
  providers = {
    aws = aws
    aws.sns = aws.sns
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  region = var.region
  fim_output_bucket = var.fim_output_bucket
  deployment_bucket = var.deployment_bucket
  python_preprocessing_bucket = var.python_preprocessing_bucket
  rnr_data_bucket = var.rnr_data_bucket
  lambda_role = var.lambda_role
  db_lambda_security_groups = var.db_lambda_security_groups
  db_lambda_subnets = var.db_lambda_subnets
  wrds_db_dump_sns = var.wrds_db_dump_sns
  viz_db_host = var.viz_db_host
  viz_db_name = var.viz_db_name
  viz_db_user_secret_string = var.viz_db_user_secret_string
  layers = [
    var.yaml_layer,
    var.viz_lambda_shared_funcs_layer,
    var.pandas_layer
  ]
  viz_pipeline_step_function_arn = var.viz_pipeline_step_function_arn
  sync_wrds_db_step_function_arn = var.sync_wrds_db_step_function_arn
  nwm_dataflow_version = var.nwm_dataflow_version
}

resource "aws_sns_topic_subscription" "viz_initialize_pipeline_subscription_shared_nwm" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  provider = aws.sns
  topic_arn = var.nws_shared_account_nwm_sns
  protocol  = "lambda"
  endpoint  = module.initialize-pipeline[0].lambda.arn
}

resource "aws_lambda_permission" "viz_initialize_pipeline_permissions_shared_nwm" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  action        = "lambda:InvokeFunction"
  function_name = module.initialize-pipeline[0].lambda.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.nws_shared_account_nwm_sns
}

resource "aws_sns_topic_subscription" "viz_initialize_pipeline_subscription_wrds_db_dump" {
  count = contains(local.official_environments, var.environment) ? 1 : 0
  provider = aws.sns
  topic_arn = var.wrds_db_dump_sns
  protocol  = "lambda"
  endpoint  = module.initialize-pipeline[0].lambda.arn
}

resource "aws_lambda_permission" "viz_initialize_pipeline_permissions_wrds_db_dump" {
  count = contains(local.official_environments, var.environment) ? 1 : 0
  action        = "lambda:InvokeFunction"
  function_name = module.initialize-pipeline[0].lambda.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.wrds_db_dump_sns
}

resource "aws_lambda_function_event_invoke_config" "viz_initialize_pipeline_destinations" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  function_name          = module.initialize-pipeline[0].lambda.function_name
  maximum_retry_attempts = 0
  destination_config {
    on_failure {
      destination = var.email_sns_topics["viz_lambda_errors"].arn
    }
  }
}

resource "aws_cloudwatch_event_target" "viz_initialize_pipeline_every_five_minutes" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  rule      = var.five_minute_trigger.name
  target_id = module.initialize-pipeline[0].lambda.function_name
  arn       = module.initialize-pipeline[0].lambda.arn
  input     = "{\"configuration\":\"rfc\"}"
}

resource "aws_lambda_permission" "viz_initialize_pipeline_called_by_rule" {
  count         = contains(local.prodlike_environments, var.environment) ? 1 : 0
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = module.initialize-pipeline[0].lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.five_minute_trigger.arn
}

######################
## OPTIMIZE RASTERS ##
######################

module "optimize-rasters" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.optimize_rasters, false) ? 1 : 0
  source = "./optimize_rasters"
  providers = {
    aws     = aws
    aws.sns = aws.sns
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  account_id = var.account_id
  region = var.region
  deployment_bucket = var.deployment_bucket
  lambda_role = var.lambda_role
  default_tags = var.default_tags
  ecr_repository_image_tag = local.ecr_repository_image_tag
  lambda_name = "hv-vpp-${var.environment}-${local.optimize_rasters}"
  profile = var.profile
  execute_codebuild_function_name = var.execute_codebuild_function_name_override != null ? var.execute_codebuild_function_name_override : module.execute-codebuild[0].lambda.function_name
}

#############################
##     Publish Service     ##
#############################
module "publish-service" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.publish_service, false) ? 1 : 0
  source = "./publish_service"
  providers = {
    aws     = aws
    aws.sns = aws.sns
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  region = var.region
  deployment_bucket = var.deployment_bucket
  python_preprocessing_bucket = var.python_preprocessing_bucket
  viz_authoritative_bucket = var.viz_authoritative_bucket
  egis_portal_password = var.egis_portal_password
  lambda_role = var.lambda_role
  db_lambda_security_groups = var.db_lambda_security_groups
  db_lambda_subnets = var.db_lambda_subnets
  egis_db_host = var.egis_db_host
  egis_db_name = var.egis_db_name
  egis_db_user_secret_string = var.egis_db_user_secret_string
  layers = [
    var.yaml_layer,
    var.arcgis_python_api_layer,
    var.viz_lambda_shared_funcs_layer
  ]
}

resource "aws_lambda_function_event_invoke_config" "viz_publish_service_destinations" {
  count     = contains(local.prodlike_environments, var.environment) ? 1 : 0
  function_name          = module.publish-service[0].lambda.function_name
  maximum_retry_attempts = 0
  destination_config {
    on_failure {
      destination = var.email_sns_topics["viz_lambda_errors"].arn
    }
  }
}

resource "aws_s3_object" "viz_publish_mapx_files" {
  provider = aws.no_tags 
  for_each    = lookup(var.creation_map, local.publish_service, false) ? fileset("${path.module}/publish_service/deploy/code/services", "**/*.mapx") : []
  bucket      = var.deployment_bucket
  key         = "viz_mapx/${var.environment}/${reverse(split("/",each.key))[0]}"
  source      = "${path.module}/publish_service/deploy/code/services/${each.key}"
  source_hash = filemd5("${path.module}/publish_service/deploy/code/services/${each.key}")
}

##########################
## PYTHON PREPROCESSING ##
##########################
module "python-preprocessing" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.python_preprocessing, false) ? 1 : 0
  source = "./python_preprocessing"
  providers = {
    aws = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  account_id = var.account_id
  region = var.region
  ecr_repository_image_tag = local.ecr_repository_image_tag
  lambda_role = var.lambda_role
  security_groups = var.db_lambda_security_groups
  subnets = var.db_lambda_subnets
  deployment_bucket = var.deployment_bucket
  viz_db_name = var.viz_db_name
  viz_db_host = var.viz_db_host
  viz_db_user_secret_string = var.viz_db_user_secret_string
  viz_authoritative_bucket = var.viz_authoritative_bucket
  default_tags = var.default_tags
  profile = var.profile
  execute_codebuild_function_name = var.execute_codebuild_function_name_override != null ? var.execute_codebuild_function_name_override : module.execute-codebuild[0].lambda.function_name
}

#######################
## RASTER PROCESSING ##
#######################
module "raster-processing" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.raster_processing, false) ? 1 : 0
  source = "./raster_processing"
  providers = {
    aws = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  account_id = var.account_id
  region = var.region
  deployment_bucket = var.deployment_bucket
  lambda_role = var.lambda_role
  default_tags = var.default_tags
  nwm_dataflow_version = var.nwm_dataflow_version
  ecr_repository_image_tag = local.ecr_repository_image_tag
  lambda_name = "hv-vpp-${var.environment}-${local.raster_processing}"
  profile = var.profile
  execute_codebuild_function_name = var.execute_codebuild_function_name_override != null ? var.execute_codebuild_function_name_override : module.execute-codebuild[0].lambda.function_name
}

###########################
## SCHISM FIM PROCESSING ##
###########################
module "schism-fim" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.schism_fim_processing, false) ? 1 : 0
  source = "./schism_fim_processing"
  providers = {
    aws     = aws
    aws.no_tags = aws.no_tags
  }
  environment                 = var.environment
  account_id                  = var.account_id
  region                      = var.region
  ecr_repository_image_tag    = local.ecr_repository_image_tag
  codebuild_role              = var.lambda_role
  security_groups             = var.db_lambda_security_groups
  subnets                     = var.db_lambda_subnets
  deployment_bucket           = var.deployment_bucket
  profile_name                = var.environment
  viz_db_name                 = var.viz_db_name
  viz_db_host                 = var.viz_db_host
  viz_db_user_secret_string   = var.viz_db_user_secret_string
  execute_codebuild_function_name = var.execute_codebuild_function_name_override != null ? var.execute_codebuild_function_name_override : module.execute-codebuild[0].lambda.function_name
}

##################
## TEST WRDS DB ##
##################
module "test-wrds-db" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.test_wrds_db, false) ? 1 : 0
  source = "./test_wrds_db"
  providers = {
    aws     = aws
    aws.sns = aws.sns
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  region = var.region
  deployment_bucket = var.deployment_bucket
  lambda_role = var.lambda_role
  db_lambda_security_groups = var.db_lambda_security_groups
  db_lambda_subnets = var.db_lambda_subnets
  viz_db_host = var.viz_db_host
  viz_db_name = var.viz_db_name
  viz_db_suser_secret_string = var.viz_db_suser_secret_string
  wrds_db_user_secret_string = var.wrds_db_user_secret_string
  wrds_db_host = var.wrds_db_host
  layers = [
    var.psycopg2_sqlalchemy_layer,
    var.viz_lambda_shared_funcs_layer
  ]
}

######################
## UPDATE EGIS DATA ##
######################
module "update-egis-data" {
  count = lookup(var.creation_map, "all", false) || lookup(var.creation_map, local.update_egis_data, false) ? 1 : 0
  source = "./update_egis_data"
  providers = {
    aws = aws
    aws.no_tags = aws.no_tags
  }
  environment = var.environment
  account_id = var.account_id
  region = var.region
  ecr_repository_image_tag = local.ecr_repository_image_tag
  lambda_role = var.lambda_role
  security_groups = var.db_lambda_security_groups
  subnets = var.db_lambda_subnets
  deployment_bucket = var.deployment_bucket
  viz_db_name = var.viz_db_name
  viz_db_host = var.viz_db_host
  viz_db_user_secret_string = var.viz_db_user_secret_string
  egis_db_host = var.egis_db_host
  egis_db_name = var.egis_db_name
  egis_db_user_secret_string = var.egis_db_user_secret_string
  viz_cache_bucket = var.viz_cache_bucket
  default_tags = var.default_tags
  profile = var.profile
  execute_codebuild_function_name = var.execute_codebuild_function_name_override != null ? var.execute_codebuild_function_name_override : module.execute-codebuild[0].lambda.function_name
}