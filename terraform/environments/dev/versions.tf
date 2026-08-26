terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Remote state is intentionally NOT configured by default.
  #
  # Local state is fine for a single-operator lab, and a GCS backend bucket is
  # one more resource to remember to delete. For any shared or production use,
  # uncomment this and create the bucket first with versioning enabled - state
  # files contain resource attributes and must never live only on a laptop.
  #
  # backend "gcs" {
  #   bucket = "CHANGE-ME-tfstate-bucket"
  #   prefix = "gke-migration/dev"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # Applied to every resource that supports labels, for cost attribution in the
  # billing export. Without labels you cannot answer "what is this costing me".
  default_labels = {
    application = var.app_name
    environment = var.environment
    managed-by  = "terraform"
  }
}
