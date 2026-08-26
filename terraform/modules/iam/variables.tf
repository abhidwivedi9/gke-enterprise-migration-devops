variable "project_id" { type = string }
variable "name_prefix" { type = string }

variable "app_namespace" {
  description = "Kubernetes namespace the app runs in. Must match the Helm release namespace exactly."
  type        = string
  default     = "orders"
}

variable "app_ksa_name" {
  description = "Kubernetes ServiceAccount name. Must match the KSA the Helm chart creates, exactly."
  type        = string
  default     = "orders-api"
}

variable "workload_roles" {
  description = "Project roles for the application identity. Add narrowly; never roles/editor."
  type        = list(string)
  default = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ]
}

variable "enable_github_oidc" {
  description = "Create the Workload Identity Federation pool for GitHub Actions. Free."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "owner/repo. Pins the OIDC provider so no other repository can mint an accepted token."
  type        = string
  default     = "OWNER/REPO"
}

variable "ci_roles" {
  description = "What the CI identity may do. container.developer deploys workloads but cannot touch the cluster itself."
  type        = list(string)
  default = [
    "roles/container.developer",
    "roles/iam.serviceAccountTokenCreator",
  ]
}
