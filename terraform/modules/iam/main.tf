/**
 * IAM module - identities, least privilege, and keyless CI authentication.
 *
 * COST: free. IAM resources, service accounts and Workload Identity Federation
 * carry no charge. There is no reason not to do this properly.
 *
 * Three identities are created here:
 *
 *   1. node SA        - what the GKE nodes run as
 *   2. workload SA    - what the APPLICATION POD authenticates to Google as,
 *                       via Workload Identity (no JSON key)
 *   3. CI SA + WIF    - what GitHub Actions impersonates, via OIDC
 *                       (no JSON key)
 *
 * Not one long-lived service-account key is created anywhere in this module.
 * That is the point. A leaked SA key is the most common cause of a real GCP
 * compromise, and the only way to guarantee one does not leak is to not have
 * one.
 */

# ---------------------------------------------------------------------------
# 1. GKE node service account.
#
# GKE defaults to the Compute Engine default service account, which holds
# roles/editor across the whole project. Any pod that escapes its container -
# or simply reads the node metadata endpoint - inherits project-wide write
# access. Replacing it with this SA is the highest-value, lowest-effort GKE
# hardening step there is.
#
# The three roles below are the documented minimum for a functioning node.
# ---------------------------------------------------------------------------
resource "google_service_account" "node" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-node-sa"
  display_name = "GKE node SA (${var.name_prefix})"
  description  = "Least-privilege identity for GKE nodes. Replaces the Compute Engine default SA."
}

locals {
  # Exactly what a node needs, and nothing else.
  node_roles = [
    "roles/logging.logWriter",                   # ship node + container logs
    "roles/monitoring.metricWriter",             # ship node metrics
    "roles/monitoring.viewer",                   # read back its own metrics for autoscaling
    "roles/stackdriver.resourceMetadata.writer", # node metadata for the console
  ]
}

resource "google_project_iam_member" "node" {
  for_each = toset(local.node_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.node.email}"
}

# NOTE: artifactregistry.reader is deliberately NOT granted here at project
# level. The artifact-registry module grants it on the single repository
# instead, which is narrower. Project-level reader would let nodes pull from
# every repo in the project.

# ---------------------------------------------------------------------------
# 2. Application workload identity.
#
# The pod runs as a Kubernetes ServiceAccount. That KSA is bound to this Google
# SA. When application code calls a Google API, the GKE metadata server mints a
# short-lived token for this SA. No key material ever exists on disk.
#
# The binding has two halves and BOTH are required:
#   - here:  IAM policy on the GSA granting workloadIdentityUser to the KSA
#   - Helm:  the KSA carries the annotation
#              iam.gke.io/gcp-service-account: <this SA email>
#
# Miss either half and you get a 403 from the metadata server that says nothing
# useful. That is failure-lab scenario 12.
# ---------------------------------------------------------------------------
resource "google_service_account" "workload" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-app-sa"
  display_name = "Application workload SA (${var.name_prefix})"
  description  = "Identity the orders-api pods authenticate to Google APIs as."
}

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.workload.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.app_namespace}/${var.app_ksa_name}]"
}

# The application only needs to write logs and metrics. If it later needs
# Secret Manager or Cloud SQL, add the specific role here - never roles/editor.
resource "google_project_iam_member" "workload" {
  for_each = toset(var.workload_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.workload.email}"
}

# ---------------------------------------------------------------------------
# 3. GitHub Actions via Workload Identity Federation (OIDC).
#
# The alternative - generating a JSON key and pasting it into a GitHub secret -
# gives GitHub a credential that never expires, works from anywhere on earth,
# and appears in plaintext in any workflow that accidentally echoes it.
#
# WIF replaces that with: GitHub mints a short-lived OIDC token describing the
# exact repo, branch and workflow; GCP validates it against the conditions
# below and exchanges it for a 1-hour access token. Nothing to leak, nothing to
# rotate.
# ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  count = var.enable_github_oidc ? 1 : 0

  project                   = var.project_id
  workload_identity_pool_id = "${var.name_prefix}-gh-pool"
  display_name              = "GitHub Actions pool"
  description               = "Federated identity pool for GitHub Actions OIDC"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count = var.enable_github_oidc ? 1 : 0

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  # Map GitHub's token claims onto Google attributes so they can be asserted on.
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # THE CRITICAL LINE. Without an attribute_condition, ANY GitHub repository on
  # github.com - including one an attacker creates - can mint a token this
  # provider accepts. Pinning to your repository is mandatory.
  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "ci" {
  count = var.enable_github_oidc ? 1 : 0

  project      = var.project_id
  account_id   = "${var.name_prefix}-ci-sa"
  display_name = "GitHub Actions CI SA (${var.name_prefix})"
  description  = "Impersonated by GitHub Actions via OIDC. Has no keys."
}

# Allow the federated GitHub identity to impersonate the CI service account,
# but only from the specific repository named above.
resource "google_service_account_iam_member" "ci_impersonation" {
  count = var.enable_github_oidc ? 1 : 0

  service_account_id = google_service_account.ci[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github_repository}"
}

# What CI is allowed to do once it has impersonated the SA.
#
# container.developer lets it deploy workloads but NOT create, modify or delete
# clusters - a pipeline should never be able to delete the cluster it deploys
# to. Note artifactregistry.writer is granted per-repository by the
# artifact-registry module, not here.
resource "google_project_iam_member" "ci" {
  for_each = var.enable_github_oidc ? toset(var.ci_roles) : toset([])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ci[0].email}"
}
