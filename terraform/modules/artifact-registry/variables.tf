variable "project_id" { type = string }

variable "location" {
  description = "MUST match the GKE cluster's region, or every image pull is billed as cross-region egress."
  type        = string
}

variable "name_prefix" { type = string }
variable "environment" { type = string }

variable "repository_id" {
  description = "Repository name. Final image path is LOCATION-docker.pkg.dev/PROJECT/REPO_ID/IMAGE:TAG."
  type        = string
  default     = "orders"
}

variable "immutable_tags" {
  description = "Once true, a tag can never be repointed. This is the guardrail against non-deterministic deploys."
  type        = bool
  default     = true
}

variable "cleanup_dry_run" {
  description = "true = evaluate and log, delete nothing. Confirm the policy is right before setting false."
  type        = bool
  default     = true
}

variable "keep_recent_count" {
  type    = number
  default = 10
}

variable "untagged_retention_days" {
  description = "Untagged images are orphaned layers from overwritten builds - pure cost."
  type        = number
  default     = 7
}

variable "node_service_account_email" {
  description = "GKE node SA. Gets artifactregistry.reader, never writer."
  type        = string
}

variable "ci_service_account_email" {
  description = "CI SA impersonated via Workload Identity Federation. Gets writer on this repo only. Empty = skip."
  type        = string
  default     = ""
}
