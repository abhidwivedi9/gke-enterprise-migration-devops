variable "project_id" { type = string }

variable "zone" {
  description = "A ZONE (e.g. us-central1-a) creates a zonal cluster. Passing a region here triples node cost."
  type        = string
}

variable "name_prefix" { type = string }

variable "environment" {
  description = "dev | staging | prod - used for resource labels and cost attribution."
  type        = string
}

variable "network_name" { type = string }
variable "subnet_name" { type = string }
variable "pods_range_name" { type = string }
variable "services_range_name" { type = string }
variable "node_tag" { type = string }

variable "node_service_account_email" {
  description = "Least-privilege SA for nodes. Never the Compute Engine default SA."
  type        = string
}

variable "release_channel" {
  description = "RAPID | REGULAR | STABLE. REGULAR is the sane default."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "machine_type" {
  description = "COST DRIVER. e2-small = 2 shared vCPU / 2GB, the smallest type that reliably runs GKE system pods plus a small app."
  type        = string
  default     = "e2-small"
}

variable "disk_size_gb" {
  description = "COST DRIVER. 30GB is close to the practical floor for a GKE node image plus container layers."
  type        = number
  default     = 30
}

variable "disk_type" {
  description = "pd-standard (cheapest) | pd-balanced | pd-ssd. pd-ssd is roughly 4x pd-standard."
  type        = string
  default     = "pd-standard"
}

variable "use_spot_vms" {
  description = "60-91% cheaper. Google may reclaim the node with 30s notice. Correct for this lab, wrong for stateful prod."
  type        = bool
  default     = true
}

variable "node_count" {
  description = "Used only when enable_autoscaling = false."
  type        = number
  default     = 1
}

variable "enable_autoscaling" {
  type    = bool
  default = true
}

variable "min_node_count" {
  type    = number
  default = 1
}

variable "max_node_count" {
  description = "HARD CEILING ON YOUR COMPUTE BILL. Keep this small."
  type        = number
  default     = 3
}

variable "enable_private_nodes" {
  description = "Nodes get no external IP. Free, and strictly more secure. Needs private_ip_google_access on the subnet."
  type        = bool
  default     = true
}

variable "master_ipv4_cidr" {
  type    = string
  default = "172.16.0.0/28"
}

variable "authorized_networks" {
  description = "CIDRs allowed to reach the Kubernetes API. Empty list = open to the internet (still authenticated)."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "enable_http_load_balancing" {
  description = "COSTS MONEY (~$18/mo per forwarding rule, billed at zero traffic). Only enable when you need a real Ingress."
  type        = bool
  default     = false
}

variable "enable_managed_prometheus" {
  description = "COSTS MONEY beyond the free sample allowance. Needed for application dashboards in Cloud Monitoring."
  type        = bool
  default     = false
}

variable "enable_workload_logging" {
  description = "Ships container stdout to Cloud Logging. Free to 50 GiB/project/month, then $0.50/GiB."
  type        = bool
  default     = true
}

variable "node_labels" {
  type    = map(string)
  default = {}
}
