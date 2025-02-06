variable "environment" {
  type = string
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "ecr_repository_image_tag" {
  type = string
  default = "latest"
}

variable "security_groups" {
  type = list(string)
}

variable "subnets" {
  type = list(string)
}

variable "deployment_bucket" {
  type = string
}

variable "viz_db_name" {
  type = string
}

variable "viz_db_host" {
  type = string
}

variable "viz_db_user_secret_string" {
  type = string
}

variable "viz_authoritative_bucket" {
  type = string
}

variable "lambda_role" {
  type = string
}

variable "default_tags" {
  type = map(string)
}