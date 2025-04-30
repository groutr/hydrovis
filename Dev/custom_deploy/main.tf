terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      configuration_aliases = [ aws.sns, aws.no_tags]
    }
  }
}

module "viz-lambda-functions" {
  source = "../../Core/LAMBDA/viz_functions"
  providers = {
    aws     = aws
    aws.sns = aws.sns
    aws.no_tags = aws.no_tags
  }
  environment                    = var.personal_tag
  account_id                     = var.account_id
  region                         = var.region
  viz_authoritative_bucket       = var.s3_buckets["deployment"].bucket
  fim_data_bucket                = var.s3_buckets["deployment"].bucket
  fim_output_bucket              = var.s3_buckets["fim"].bucket
  python_preprocessing_bucket    = var.s3_buckets["fim"].bucket
  rnr_data_bucket                = var.s3_buckets["rnr"].bucket
  deployment_bucket              = var.s3_buckets["deployment"].bucket
  viz_cache_bucket               = var.s3_buckets["fim"].bucket
  fim_version                    = var.fim_version
  hand_version                   = var.hand_version
  lambda_role                    = var.viz_role
  nws_shared_account_nwm_sns     = "unnecessary for developer deploy"
  wrds_db_dump_sns               = "unnecessary for developer deploy"
  email_sns_topics               = {}
  es_logging_layer               = var.lambda_functions["viz-fim-data-prep"].layers[2]
  xarray_layer                   = var.lambda_functions["viz-fim-data-prep"].layers[1]
  pandas_layer                   = var.lambda_functions["viz-initialize-pipeline"].layers[2]
  geopandas_layer                = "not used anywhere"
  arcgis_python_api_layer        = var.lambda_functions["viz-publish-service"].layers[1]
  psycopg2_sqlalchemy_layer      = var.lambda_functions["viz-db-postprocess-sql"].layers[0]
  requests_layer                 = var.lambda_functions["egis-health-checker"].layers[0]
  yaml_layer                     = var.lambda_functions["viz-initialize-pipeline"].layers[0]
  dask_layer                     = "not used anywhere"
  viz_lambda_shared_funcs_layer  = var.lambda_functions["viz-initialize-pipeline"].layers[1]
  db_lambda_security_groups      = var.lambda_functions["viz-initialize-pipeline"].vpc_config[0].security_group_ids
  db_lambda_subnets              = var.lambda_functions["viz-initialize-pipeline"].vpc_config[0].subnet_ids
  viz_db_host                    = var.viz_db_host
  viz_db_name                    = var.viz_db_name
  viz_db_user_secret_string      = var.secrets["viz-proc-admin-rw-user"].secret_string
  viz_db_suser_secret_string     = var.secrets["viz-processing-pg-rdssecret"].secret_string
  wrds_db_host                   = var.wrds_db_host
  wrds_db_user_secret_string     = var.secrets["ingest-pg-rdssecret"].secret_string
  egis_db_host                   = var.egis_db_host
  egis_db_name                   = var.egis_db_name
  egis_db_user_secret_string     = var.secrets["egis-pg-rds-secret"].secret_string
  egis_portal_password           = "come back to this"
  viz_pipeline_step_function_arn = var.step_functions["viz-pipeline"].arn
  sync_wrds_db_step_function_arn = var.step_functions["sync-wrds-location-db"].arn
  default_tags                   = var.default_tags
  nwm_dataflow_version           = var.nwm_dataflow_version
  five_minute_trigger            = {name="not used", arn="not_used"}
  profile                        = var.profile
  creation_map                   = var.deploy_resources
  execute_codebuild_function_name_override = lookup(var.deploy_resources, "execute-codebuild", false) ? null : var.lambda_functions["execute-codebuild"].function_name
}

################################
################################
## VIZ PIPELINE STEP FUNCTION ##
################################
################################
module "viz-step-functions" {
  count = lookup(var.deploy_resources, "viz-pipeline", false) ? 1 : 0
  source = "../../Core/StepFunctions/viz"

  environment = var.personal_tag
  viz_lambda_role = var.viz_role
  optimize_rasters_arn = lookup(var.deploy_resources, "optimize-rasters", false) ? module.viz-lambda-functions.optimize_rasters.arn : var.lambda_functions["viz-optimize-rasters"].arn
  update_egis_data_arn = lookup(var.deploy_resources, "update-egis-data", false) ? module.viz-lambda-functions.update_egis_data.arn : var.lambda_functions["viz-update-egis-data"].arn
  fim_data_prep_arn = lookup(var.deploy_resources, "fim-data-prep", false) ? module.viz-lambda-functions.fim_data_prep.arn : var.lambda_functions["viz-fim-data-prep"].arn
  db_postprocess_sql_arn = lookup(var.deploy_resources, "db-postprocess-sql", false) ? module.viz-lambda-functions.db_postprocess_sql.arn : var.lambda_functions["viz-db-postprocess-sql"].arn
  db_ingest_arn = lookup(var.deploy_resources, "db-ingest", false) ? module.viz-lambda-functions.db_ingest.arn : var.lambda_functions["viz-db-ingest"].arn
  raster_processing_arn = lookup(var.deploy_resources, "raster-processing", false) ? module.viz-lambda-functions.raster_processing.arn : var.lambda_functions["viz-raster-processing"].arn
  publish_service_arn = lookup(var.deploy_resources, "publish-service", false) ? module.viz-lambda-functions.publish_service.arn : var.lambda_functions["viz-publish-service"].arn
  python_preprocessing_3GB_arn = lookup(var.deploy_resources, "python-preprocessing", false) ? module.viz-lambda-functions.python_preprocessing.arn : var.lambda_functions["viz-python-preprocessing"].arn
  python_preprocessing_10GB_arn = lookup(var.deploy_resources, "python-preprocessing", false) ? module.viz-lambda-functions.python_preprocessing.arn : var.lambda_functions["viz-python-preprocessing"].arn
  viz_processing_pipeline_log_group = var.cloudwatch_log_groups["viz-processing-pipeline"].name
  email_sns_topics = {}
  schism_fim_datasets_bucket = var.s3_buckets["deployment"].bucket
  schism_fim_job_definition_arn = lookup(var.deploy_resources, "schism-fim-processing", false) ? module.viz-lambda-functions.schism_fim.job_definition.arn : "arn:aws:batch:${var.region}:${var.account_id}:job-definition/hv-vpp-ti-schism-fim-job-definition:2"
  schism_fim_job_queue_arn = lookup(var.deploy_resources, "schism-fim-processing", false) ? module.viz-lambda-functions.schism_fim.job_queue.arn : "arn:aws:batch:${var.region}:${var.account_id}:job-queue/hv-vpp-ti-schism-fim-job-queue"
  hand_fim_processing_arn = lookup(var.deploy_resources, "hand-fim-processing", false) ? module.viz-lambda-functions.hand_fim_processing.arn : var.lambda_functions["viz-hand-fim-processing"].arn
  hand_fim_processing_step_function_arn_override = lookup(var.deploy_resources, "hand-fim-processing", false) ? null : var.step_functions["hand-fim-processing"].arn
  schism_fim_processing_step_function_arn_override = lookup(var.deploy_resources, "schism-fim-processing", false) ? null : var.step_functions["process-schism-fim"].arn
}