variable "env" {
  description = "Environment name (see the stack root's var.env); suffixes the function and role names."
  type        = string
}

variable "model_id" {
  description = "Bedrock model or inference profile ID the function invokes; the caller cannot override it."
  type        = string
}

variable "bedrock_region" {
  description = "Region Bedrock is called in; scopes the inference profile ARN."
  type        = string
}
