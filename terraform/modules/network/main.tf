/**
 * Network module - the VPC the migrated workload lands in.
 *
 * COST: every resource in this module is free to exist. A VPC, a subnet,
 * routes and firewall rules carry no hourly charge. The one exception is
 * Cloud NAT (var.enable_cloud_nat), which bills per gateway-hour plus data
 * processed and is therefore DEFAULT OFF. See COST_CONTROL.md.
 */

# ---------------------------------------------------------------------------
# VPC
#
# auto_create_subnetworks = false gives us a "custom mode" VPC. Auto mode
# creates a /20 subnet in every region on the planet, which is convenient for a
# demo and wrong for an enterprise: it burns address space you may need for
# on-prem peering and it silently widens your blast radius. Every enterprise
# migration lands in custom mode.
# ---------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL" # GLOBAL only matters once you have multiple regions
  description             = "VPC for the ${var.name_prefix} GKE migration target"

  # Deleting a VPC that still has dependents fails noisily; this makes
  # `terraform destroy` clean up in the right order.
  delete_default_routes_on_create = false
}

# ---------------------------------------------------------------------------
# Subnet with secondary ranges - the part that trips people up on GKE.
#
# A VPC-native (alias IP) GKE cluster does NOT put pods on the primary range.
# It needs two SECONDARY ranges: one for pods, one for services. Get the sizing
# wrong and you cannot scale later without rebuilding the cluster, because
# secondary ranges cannot be resized in place while in use.
#
# Sizing maths for the defaults below:
#   pods     10.4.0.0/14  = 262,144 addresses
#     GKE allocates a /24 (256 addresses) per node by default, and the node can
#     run at most 110 pods. /14 therefore supports ~1024 nodes. Generous, free.
#   services 10.8.0.0/20  = 4,096 ClusterIPs. More than enough for one cluster.
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name_prefix}-subnet"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr # nodes and internal load balancers live here

  # Required for Private Google Access: lets nodes without external IPs reach
  # Google APIs (Artifact Registry, Cloud Logging, Cloud Monitoring) over
  # Google's internal network - WITHOUT a Cloud NAT gateway. This is the single
  # most effective cost lever on a private cluster.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${var.name_prefix}-pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "${var.name_prefix}-services"
    ip_cidr_range = var.services_cidr
  }

  # Flow logs are genuinely useful for network incident forensics, but they are
  # billed per GB ingested into Cloud Logging. Default off; turn on during an
  # actual network investigation, then turn it back off.
  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_10_MIN"
      flow_sampling        = 0.5
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# ---------------------------------------------------------------------------
# Firewall: allow the GKE control plane to reach webhooks on the nodes.
#
# On a private cluster the control plane lives in a Google-managed VPC peered to
# yours, and by default it may only reach nodes on 10250 (kubelet) and 443.
# Any admission webhook, metrics-server or custom API service listening on
# another port will time out with an error that looks nothing like a firewall
# problem: "failed calling webhook ... context deadline exceeded".
# This rule is the fix, and the symptom is failure-lab scenario 14.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_control_plane_to_webhooks" {
  name        = "${var.name_prefix}-allow-cp-webhooks"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "GKE control plane -> node webhook/metrics ports"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.master_ipv4_cidr]
  target_tags   = ["${var.name_prefix}-node"]

  allow {
    protocol = "tcp"
    ports    = ["8443", "9443", "15017", "10250"]
  }
}

# ---------------------------------------------------------------------------
# Firewall: deny-all egress is NOT set here on purpose.
#
# GCP's implied rules already deny all ingress and allow all egress. Locking
# egress down is correct for a real production VPC, but it breaks image pulls
# and Google API access in ways that are confusing to debug, so it belongs in a
# hardening exercise rather than the baseline. SECURITY.md documents what a
# production egress policy looks like.
#
# We do add internal-traffic allow, because the implied rules do not permit
# node-to-node communication.
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_internal" {
  name        = "${var.name_prefix}-allow-internal"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Node-to-node and pod-to-pod traffic inside the VPC"
  direction   = "INGRESS"
  priority    = 1100

  source_ranges = [var.subnet_cidr, var.pods_cidr]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

# ---------------------------------------------------------------------------
# Cloud Router + Cloud NAT - OPTIONAL, COSTS MONEY.
#
# Only needed if you run private nodes AND need egress to the public internet
# (pulling from Docker Hub, calling a third-party API). If every image comes
# from Artifact Registry and every Google API call goes over Private Google
# Access, you do not need NAT at all.
#
# Billing: ~$0.044/gateway-hour (~$32/month) + $0.045/GB processed.
# ---------------------------------------------------------------------------
resource "google_compute_router" "router" {
  count   = var.enable_cloud_nat ? 1 : 0
  name    = "${var.name_prefix}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count   = var.enable_cloud_nat ? 1 : 0
  name    = "${var.name_prefix}-nat"
  project = var.project_id
  region  = var.region
  router  = google_compute_router.router[0].name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = false # NAT logs bill into Cloud Logging
    filter = "ERRORS_ONLY"
  }
}
