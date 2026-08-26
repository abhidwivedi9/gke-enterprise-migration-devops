/**
 * GKE module - the migration target cluster.
 *
 * COST WARNING. This is the only module in the repo that creates continuously
 * billed resources. Two separate charges apply:
 *
 *   1. Cluster management fee: $0.10/hour (~$72/month) per cluster.
 *      GKE's free tier gives one zonal or Autopilot cluster per BILLING ACCOUNT
 *      a $74.40/month credit, which cancels this out - for ONE cluster only.
 *      A second cluster is billed in full.
 *
 *   2. Node VMs: billed as normal Compute Engine instances. The free tier does
 *      NOT cover these. The defaults here (1 x e2-small, SPOT, 30GB pd-standard)
 *      land at roughly $4-6/month. On-demand instead of Spot is ~3x that.
 *
 * Nothing here is free once nodes exist. `scripts/destroy-gcp.sh` is the
 * shutdown path and COST_CONTROL.md is the full breakdown.
 */

# ---------------------------------------------------------------------------
# The cluster.
#
# Design choices and why, since every one of these is an interview question:
#
#  - ZONAL, not regional. A regional cluster replicates the control plane
#    across three zones and runs your node pool in each of them - so
#    node_count = 1 becomes three VMs, tripling the compute bill. Regional is
#    the right answer for production; zonal is the right answer for a
#    cost-controlled migration rehearsal. Say exactly that in an interview.
#
#  - VPC-native (ip_allocation_policy set). Routes-based clusters are legacy;
#    alias IPs are required for Workload Identity, NEG-backed load balancing
#    and Private Google Access to behave properly.
#
#  - remove_default_node_pool. Terraform cannot manage the node pool that
#    google_container_cluster creates inline without recreating the cluster on
#    every change. Standard practice: create the cluster with a throwaway
#    default pool, delete it, and manage real pools as separate resources.
# ---------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  name     = "${var.name_prefix}-gke"
  project  = var.project_id
  location = var.zone # a bare zone => zonal cluster; a region => regional

  network    = var.network_name
  subnetwork = var.subnet_name

  remove_default_node_pool = true
  initial_node_count       = 1

  # Set to false so `terraform destroy` actually works. In real production this
  # must be TRUE - it is the guardrail that stops an accidental `destroy` from
  # deleting a live cluster. It is false here precisely because the goal of this
  # project is that you can always tear everything down.
  deletion_protection = false

  # Release channel: Google manages control-plane and node upgrades for you.
  # REGULAR is the sane default (a few weeks behind RAPID, well tested).
  # Choosing a channel is what stops you from running an unsupported version
  # 18 months into a migration.
  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # -------------------------------------------------------------------------
  # Workload Identity - how pods authenticate to Google APIs WITHOUT a
  # service-account JSON key mounted as a Secret. The Kubernetes ServiceAccount
  # is bound to a Google service account, and the GKE metadata server issues
  # short-lived tokens. No long-lived key exists to leak.
  #
  # This is the single most important security control in the whole cluster,
  # and it is free.
  # -------------------------------------------------------------------------
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # -------------------------------------------------------------------------
  # Private nodes: nodes get no external IP. Combined with the subnet's
  # private_ip_google_access, they can still pull from Artifact Registry and
  # write to Cloud Logging without a NAT gateway.
  #
  # enable_private_endpoint = false keeps the CONTROL PLANE publicly reachable
  # (locked down by master_authorized_networks below), so you can run kubectl
  # from your laptop. Setting it true requires a bastion or VPN and is a
  # meaningful operational burden - correct for prod, overkill here.
  # -------------------------------------------------------------------------
  dynamic "private_cluster_config" {
    for_each = var.enable_private_nodes ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = false
      master_ipv4_cidr_block  = var.master_ipv4_cidr
    }
  }

  # Restrict who may reach the Kubernetes API. Leaving this unset means the
  # control plane endpoint accepts connections from the entire internet
  # (still authenticated, but exposed to credential-stuffing and CVE scanning).
  dynamic "master_authorized_networks_config" {
    for_each = length(var.authorized_networks) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  # -------------------------------------------------------------------------
  # Logging and monitoring.
  #
  # Cloud Logging ingestion is free for the first 50 GiB/project/month, then
  # $0.50/GiB. SYSTEM_COMPONENTS alone is cheap; adding WORKLOADS ships every
  # container stdout line to Cloud Logging, which is what you actually want
  # during a migration but is also the usual source of a surprise logging bill.
  # Controlled by var.enable_workload_logging (default: true, because logging
  # you cannot query is worthless during a cutover - but see COST_CONTROL.md).
  # -------------------------------------------------------------------------
  logging_config {
    enable_components = var.enable_workload_logging ? ["SYSTEM_COMPONENTS", "WORKLOADS"] : ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]

    # Google Cloud Managed Service for Prometheus. Free for the first 100k
    # samples ingested, then billed per sample. It is how the dashboards in
    # monitoring/ get application metrics. Default OFF to keep the bill at
    # zero; turn it on when you actually want the app dashboards.
    managed_prometheus {
      enabled = var.enable_managed_prometheus
    }
  }

  # Cost-control addons.
  addons_config {
    http_load_balancing {
      # An Ingress creates a Google Cloud HTTP(S) Load Balancer: ~$18/month for
      # the forwarding rule alone, billed even with zero traffic. Default off.
      # Use `kubectl port-forward` for validation instead - it costs nothing.
      disabled = !var.enable_http_load_balancing
    }
    horizontal_pod_autoscaling {
      disabled = false # free, and required for the HPA exercises
    }
    gcp_filestore_csi_driver_config {
      enabled = false # Filestore starts at ~$200/month. Never enable casually.
    }
  }

  # Prevents Terraform from fighting GKE over fields the control plane manages
  # itself (node version during an auto-upgrade, for instance).
  lifecycle {
    ignore_changes = [
      node_config,
      initial_node_count,
    ]
  }
}

# ---------------------------------------------------------------------------
# Node pool.
#
# Separate resource so it can be replaced without touching the cluster - which
# is exactly what you do during a node-version upgrade or a machine-type change
# in a real migration (create new pool, cordon+drain old pool, delete old pool).
# ---------------------------------------------------------------------------
resource "google_container_node_pool" "primary" {
  name     = "${var.name_prefix}-pool"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.primary.name

  node_count = var.enable_autoscaling ? null : var.node_count

  dynamic "autoscaling" {
    for_each = var.enable_autoscaling ? [1] : []
    content {
      min_node_count = var.min_node_count
      max_node_count = var.max_node_count # a hard ceiling on your compute bill
    }
  }

  management {
    auto_repair  = true # replaces nodes that fail health checks
    auto_upgrade = true # required when using a release channel
  }

  # Surge upgrade: how disruptive a node upgrade is allowed to be.
  # max_surge=1 adds one extra node during the upgrade (brief extra cost, no
  # capacity loss); max_unavailable=0 means no node is removed before its
  # replacement is ready. This is what makes node upgrades non-events.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb
    disk_type    = var.disk_type # pd-standard is ~4x cheaper than pd-ssd

    # SPOT VMs: 60-91% cheaper, and Google may reclaim them with 30 seconds'
    # notice. Perfect for a learning cluster and for genuinely stateless
    # workloads; it also forces you to build software that tolerates a node
    # vanishing, which is a good habit. Never for a stateful production tier.
    spot = var.use_spot_vms

    # The node service account. Defaulting to the Compute Engine default SA is
    # the most common GKE security mistake in existence - that account has
    # project-wide Editor. This module demands a purpose-built SA with only
    # logging, monitoring and Artifact Registry read.
    service_account = var.node_service_account_email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Required for Workload Identity to function on the node.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Blocks pods from reading the legacy (v1beta1) metadata endpoints, which
    # would otherwise let any pod steal the node service account's token.
    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    tags   = [var.node_tag] # matches the firewall rules in the network module
    labels = var.node_labels

    resource_labels = {
      environment = var.environment
      managed-by  = "terraform"
      cost-center = "migration-lab"
    }
  }

  lifecycle {
    # Recreate the pool before destroying the old one when an immutable field
    # (machine_type, disk) changes, so the cluster never has zero nodes.
    create_before_destroy = false
  }
}
