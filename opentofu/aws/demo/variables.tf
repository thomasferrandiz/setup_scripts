variable "region" {
  type        = string
  description = "AWS region to deploy the demo/GPU environment into."
  default     = "eu-south-2"
}

variable "access_key" {
  type        = string
  description = "AWS access key. Leave null to use the default credential chain."
  default     = null
}

variable "secret_key" {
  type        = string
  description = "AWS secret key. Leave null to use the default credential chain."
  default     = null
  sensitive   = true
}

variable "token" {
  type        = string
  description = "AWS session token. Leave null to use the default credential chain."
  default     = null
  sensitive   = true
}
