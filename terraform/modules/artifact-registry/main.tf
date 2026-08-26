/**
 * Artifact Registry module - where migrated container images live.
 *
 * COST: storage is $0.10/GB/month beyond a 0.5GB free allowance, and egress
 * OUT of the region is billed. Pulling from GKE in the SAME region is free,
 * which is why var.location must match the cluster region. Getting this wrong
 * is a silent, recurring data-transfer charge.
 *
 * Container Registry (gcr.io) is deprecated. Artifact Registry is the only
 * correct choice for a 2026 migration - say so if asked why in an interview.
 */

resource "google_artifact_registry_repository" "docker" {
  provider = google

  project       = var.project_id
  location      = var.location
  repository_id = var.repository_id
  description   = "Container images for the ${var.name_prefix} workload"
  format        = "DOCKER"

  labels = {
    environment = var.environment
    managed-by  = "terraform"
  }

  # -------------------------------------------------------------------------
  # Immutable tags: once :2.4.17 points at a digest, it can never be moved.
  #
  # This is the fix for the entire class of "the pipeline says SUCCESS but the
  # old code is running" incidents. If a tag can be overwritten, the tag is not
  # a version - it is a mutable pointer, and your deploy is non-deterministic.
  # See docs/VERSION_VERIFICATION.md.
  # -------------------------------------------------------------------------
  docker_config {
    immutable_tags = var.immutable_tags
  }

  # -------------------------------------------------------------------------
  # Cleanup policies keep the storage bill flat. Without them, every CI run
  # adds a layer set forever.
  #
  # DRY RUN by default: policies are evaluated and logged but delete nothing,
  # so you can confirm what would be removed before arming them.
  # -------------------------------------------------------------------------
  cleanup_policy_dry_run = var.cleanup_dry_run

  cleanup_policies {
    id     = "keep-tagged-releases"
    action = "KEEP"
    condition {
      tag_state    = "TAGGED"
      tag_prefixes = ["v", "release-"]
    }
  }

  cleanup_policies {
    id     = "keep-recent-versions"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.keep_recent_count
    }
  }

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "${var.untagged_retention_days * 86400}s"
    }
  }
}

# ---------------------------------------------------------------------------
# Who may pull. The GKE node service account needs reader - and ONLY reader.
# A node that can push images is a node that can poison your supply chain.
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository_iam_member" "node_reader" {
  project    = var.project_id
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.node_service_account_email}"
}

# ---------------------------------------------------------------------------
# Who may push. Only CI, and scoped to this one repository rather than granted
# at project level. This is the difference between "CI can push to the orders
# repo" and "CI can push anywhere in the project".
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository_iam_member" "ci_writer" {
  count = var.ci_service_account_email == "" ? 0 : 1

  project    = var.project_id
  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${var.ci_service_account_email}"
}
