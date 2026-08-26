# ---------------------------------------------------------------------------
# Required - no default, so a plan cannot silently target the wrong project.
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "GCP project ID. Supplied via terraform.tfvars (gitignored) or TF_VAR_project_id."
  type        = string
}

# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------
variable "region" {
  description = "Region. us-central1 is among the cheapest and has the widest free-tier coverage."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the ZONAL cluster. Must be inside var.region."
  type        = string
  default     = "us-central1-a"
}

variable "environment" {
  type    = string
  default = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "app_name" {
  type    = string
  default = "orders-api"
}

variable "app_namespace" {
  description = "Kubernetes namespace. Must match the Helm release namespace or Workload Identity breaks."
  type        = string
  default     = "orders"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "subnet_cidr" {
  type    = string
  default = "10.0.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.4.0.0/14"
}

variable "services_cidr" {
  type    = string
  default = "10.8.0.0/20"
}

variable "master_ipv4_cidr" {
  type    = string
  default = "172.16.0.0/28"
}

variable "enable_private_nodes" {
  type    = bool
  default = true
}

variable "authorized_networks" {
  description = "Lock the Kubernetes API to your IP. Empty list = endpoint reachable from the internet."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Cost flags. Every one of these defaults to the cheap option.
# ---------------------------------------------------------------------------
variable "machine_type" {
  description = "COST DRIVER."
  type        = string
  default     = "e2-small"
}

variable "disk_size_gb" {
  type    = number
  default = 30
}

variable "use_spot_vms" {
  description = "Keep true unless you need the node to survive preemption."
  type        = bool
  default     = true
}

variable "min_node_count" {
  type    = number
  default = 1
}

variable "max_node_count" {
  description = "HARD CEILING on compute spend."
  type        = number
  default     = 3
}

variable "enable_cloud_nat" {
  description = "COSTS ~$32/mo + data. Leave false: Private Google Access covers Artifact Registry and Cloud Logging."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "COSTS Cloud Logging ingestion."
  type        = bool
  default     = false
}

variable "enable_http_load_balancing" {
  description = "COSTS ~$18/mo per forwarding rule, billed even at zero traffic. Use kubectl port-forward instead."
  type        = bool
  default     = false
}

variable "enable_managed_prometheus" {
  description = "COSTS per sample beyond the free allowance. Required for the app dashboards in monitoring/."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Registry + CI
# ---------------------------------------------------------------------------
variable "artifact_repository_id" {
  type    = string
  default = "orders"
}

variable "artifact_cleanup_dry_run" {
  description = "true = log what would be deleted, delete nothing."
  type        = bool
  default     = true
}

variable "enable_github_oidc" {
  description = "Free. Removes any need for a service-account JSON key in GitHub."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "owner/repo - pins the OIDC provider. MUST be correct or any repo could impersonate CI."
  type        = string
  default     = "OWNER/REPO"
}
