/**
 * dev environment - the composition root.
 *
 * This file wires the four modules together and is the ONLY place a real GCP
 * resource is created. Read COST_CONTROL.md before running `terraform apply`.
 *
 * Order of creation matters and Terraform infers it from the references below:
 *   apis -> iam -> network -> artifact-registry -> gke
 *
 * WHAT THIS COSTS, at the defaults, in us-central1:
 *   GKE cluster management  $72/mo, offset to $0 by the free-tier credit for
 *                           ONE zonal cluster per billing account
 *   1 x e2-small SPOT node  ~$4/mo
 *   30GB pd-standard disk   ~$1.20/mo
 *   VPC / subnet / firewall $0
 *   Artifact Registry       $0 until you exceed 0.5GB
 *   IAM / WIF               $0
 *   -----------------------------------------------------------------------
 *   Realistic total         ~$5-7/month while running, IF the free-tier credit
 *                           applies and nothing else in the project uses it.
 *
 * Anything that would push this materially higher (Cloud NAT, an Ingress load
 * balancer, Managed Prometheus, flow logs) is behind a feature flag that
 * defaults to OFF.
 */

locals {
  name_prefix = "${var.app_name}-${var.environment}"

  common_labels = {
    application = var.app_name
    environment = var.environment
    managed-by  = "terraform"
    repository  = "gke-enterprise-migration-devops"
  }
}

# ---------------------------------------------------------------------------
# Enable the APIs this stack needs.
#
# Enabling an API is free; forgetting to enable one produces a
# "Service X has not been used in project Y before or it is disabled" error
# that costs 20 minutes the first time you see it.
#
# disable_on_destroy = false because disabling an API on destroy can break
# other things in the project that were using it.
# ---------------------------------------------------------------------------
resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",              # VPC, subnets, firewall, node VMs
    "container.googleapis.com",            # GKE
    "artifactregistry.googleapis.com",     # image registry
    "iam.googleapis.com",                  # service accounts
    "iamcredentials.googleapis.com",       # short-lived token minting (WIF)
    "sts.googleapis.com",                  # the OIDC token exchange itself
    "logging.googleapis.com",              # Cloud Logging
    "monitoring.googleapis.com",           # Cloud Monitoring + dashboards
    "cloudresourcemanager.googleapis.com", # project-level IAM bindings
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Identities first - the network and cluster both reference the node SA.
# ---------------------------------------------------------------------------
module "iam" {
  source = "../../modules/iam"

  project_id  = var.project_id
  name_prefix = local.name_prefix

  app_namespace = var.app_namespace
  app_ksa_name  = var.app_name

  enable_github_oidc = var.enable_github_oidc
  github_repository  = var.github_repository

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Network.
# ---------------------------------------------------------------------------
module "network" {
  source = "../../modules/network"

  project_id  = var.project_id
  region      = var.region
  name_prefix = local.name_prefix

  subnet_cidr      = var.subnet_cidr
  pods_cidr        = var.pods_cidr
  services_cidr    = var.services_cidr
  master_ipv4_cidr = var.master_ipv4_cidr

  # Both default false. Both cost money. Do not flip these without reading
  # COST_CONTROL.md.
  enable_cloud_nat = var.enable_cloud_nat
  enable_flow_logs = var.enable_flow_logs

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Artifact Registry. Deliberately created BEFORE the cluster: you want somewhere
# to push the image to before you have anywhere to run it. That is also the
# real-world migration order.
# ---------------------------------------------------------------------------
module "artifact_registry" {
  source = "../../modules/artifact-registry"

  project_id  = var.project_id
  location    = var.region # same region as the cluster => free image pulls
  name_prefix = local.name_prefix
  environment = var.environment

  repository_id = var.artifact_repository_id

  node_service_account_email = module.iam.node_service_account_email
  ci_service_account_email   = module.iam.ci_service_account_email

  # Start in dry-run so you can see what the cleanup policy WOULD delete.
  cleanup_dry_run = var.artifact_cleanup_dry_run
}

# ---------------------------------------------------------------------------
# GKE. The only continuously billed resource in the stack.
# ---------------------------------------------------------------------------
module "gke" {
  source = "../../modules/gke"

  project_id  = var.project_id
  zone        = var.zone # a ZONE, not a region - see the module for why
  name_prefix = local.name_prefix
  environment = var.environment

  network_name        = module.network.network_name
  subnet_name         = module.network.subnet_name
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  node_tag            = module.network.node_tag
  master_ipv4_cidr    = var.master_ipv4_cidr

  node_service_account_email = module.iam.node_service_account_email

  machine_type   = var.machine_type
  disk_size_gb   = var.disk_size_gb
  use_spot_vms   = var.use_spot_vms
  min_node_count = var.min_node_count
  max_node_count = var.max_node_count

  enable_private_nodes = var.enable_private_nodes
  authorized_networks  = var.authorized_networks

  # Cost flags, all default off.
  enable_http_load_balancing = var.enable_http_load_balancing
  enable_managed_prometheus  = var.enable_managed_prometheus

  node_labels = {
    workload = var.app_name
  }
}
