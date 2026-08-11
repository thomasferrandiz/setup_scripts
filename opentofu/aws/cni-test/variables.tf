variable "region" {
  type        = string
  description = "AWS region to deploy the CNI test environment into."
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

variable "cloud_init_files" {
  type        = list(string)
  description = <<-EOT
    Cloud-init scripts for the data-plane (worker) instances, one per instance.
    The number of DP instances and multus interfaces is derived from the length
    of this list. Paths are relative to this directory. Normally set by
    infraup.sh (test-cni flavor).
  EOT
}
