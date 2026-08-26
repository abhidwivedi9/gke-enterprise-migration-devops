output "repository_name" {
  value = google_artifact_registry_repository.docker.name
}

output "registry_host" {
  description = "Docker registry host, e.g. us-central1-docker.pkg.dev."
  value       = "${var.location}-docker.pkg.dev"
}

output "image_repository_url" {
  description = "Full path prefix for images. Append /IMAGE_NAME:TAG."
  value       = "${var.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
}

output "docker_login_command" {
  description = "Configures the local Docker client to push to this registry."
  value       = "gcloud auth configure-docker ${var.location}-docker.pkg.dev"
}
