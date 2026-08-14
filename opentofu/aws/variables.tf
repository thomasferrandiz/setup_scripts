variable "region" {
  type        = string
  description = "AWS region to deploy into."
  default     = "eu-south-2"
}

# Credentials are optional. When left null the AWS provider uses the standard
# credential chain (env vars AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
# AWS_SESSION_TOKEN, shared config/credentials files, SSO, instance profiles).
# Prefer setting those env vars over hardcoding secrets in a tfvars file.
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

variable "vpc_id" {
  type        = string
  description = "ID of an existing VPC (with an IPv6 CIDR) to attach the subnet to."
}

variable "os" {
  type        = string
  description = "OS to deploy: ubuntu (dynamic latest 24.04 AMI) or sles16 (uses sles_ami)."
  default     = "ubuntu"

  validation {
    condition     = contains(["ubuntu", "sles16"], var.os)
    error_message = "os must be ubuntu or sles16."
  }
}

variable "sles_ami" {
  type        = string
  description = "SLES 16 AMI ID; only used when os=sles16. Region-specific."
  default     = "ami-0d2945b6b30408829"
}

variable "cni" {
  type        = string
  description = "CNI plugin passed into the RKE2 server cloud-init template."
  default     = "canal"
}

variable "rke2_token" {
  type        = string
  description = "Shared token for RKE2 server/agent join."
  default     = "secret"
  sensitive   = true
}

variable "cloud_init_files" {
  type        = list(string)
  description = <<-EOT
    Cloud-init scripts, one per instance. The number of instances is derived
    from the length of this list. Paths are relative to this directory, e.g.
    ["../cloud-init-scripts/installK3s_0.sh", "../cloud-init-scripts/installK3s_1.sh"].
    Normally set by infraup.sh per flavor.
  EOT
}
