output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_location" {
  value = module.gke.cluster_location
}

output "get_credentials_command" {
  description = "Run this first, before any kubectl command."
  value       = module.gke.get_credentials_command
}

output "image_repository_url" {
  description = "Push target. Append /orders-api:VERSION."
  value       = module.artifact_registry.image_repository_url
}

output "docker_login_command" {
  value = module.artifact_registry.docker_login_command
}

output "workload_service_account_email" {
  description = "Put this in helm/application/values-dev.yaml under serviceAccount.gcpServiceAccount."
  value       = module.iam.workload_service_account_email
}

output "node_service_account_email" {
  value = module.iam.node_service_account_email
}

output "github_wif_provider" {
  description = "GitHub repo secret GCP_WIF_PROVIDER. An identifier, not a credential."
  value       = module.iam.workload_identity_provider
}

output "github_ci_service_account" {
  description = "GitHub repo secret GCP_CI_SERVICE_ACCOUNT."
  value       = module.iam.ci_service_account_email
}

output "COST_REMINDER" {
  description = "Read this every time you apply."
  value       = "Nodes bill by the hour whether or not traffic flows. Run scripts/destroy-gcp.sh when you finish."
}
