output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_location" {
  value = google_container_cluster.primary.location
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint. Marked sensitive so it never lands in CI logs."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "workload_identity_pool" {
  description = "The workload pool KSA->GSA bindings must reference."
  value       = "${var.project_id}.svc.id.goog"
}

output "get_credentials_command" {
  description = "Copy-paste to configure kubectl against this cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}
