variable "project_id" {
  description = "GCP project ID the network is created in."
  type        = string
}

variable "region" {
  description = "Region for the subnet. Keep every resource in one region; cross-region traffic is billed."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. 'orders-dev'."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary range: nodes and internal load balancers."
  type        = string
  default     = "10.0.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for pods. Cannot be resized in place once in use - size it generously now."
  type        = string
  default     = "10.4.0.0/14"
}

variable "services_cidr" {
  description = "Secondary range for ClusterIP services."
  type        = string
  default     = "10.8.0.0/20"
}

variable "master_ipv4_cidr" {
  description = "The /28 the GKE control plane lives in. Must not overlap any other range."
  type        = string
  default     = "172.16.0.0/28"
}

variable "enable_cloud_nat" {
  description = "COSTS MONEY (~$32/mo + data). Only needed for private nodes that must reach the public internet."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "COSTS MONEY (Cloud Logging ingestion). Turn on only during a network investigation."
  type        = bool
  default     = false
}
