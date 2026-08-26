output "node_service_account_email" {
  value = google_service_account.node.email
}

output "workload_service_account_email" {
  description = "Annotate the Kubernetes ServiceAccount with this: iam.gke.io/gcp-service-account."
  value       = google_service_account.workload.email
}

output "ci_service_account_email" {
  value = var.enable_github_oidc ? google_service_account.ci[0].email : ""
}

output "workload_identity_provider" {
  description = "Set as the GitHub secret GCP_WIF_PROVIDER. Not sensitive - it is an identifier, not a credential."
  value       = var.enable_github_oidc ? google_iam_workload_identity_pool_provider.github[0].name : ""
}

output "github_actions_auth_snippet" {
  description = "Drop-in block for a GitHub Actions job. Requires permissions: id-token: write."
  value = var.enable_github_oidc ? join("\n", [
    "- uses: google-github-actions/auth@v2",
    "  with:",
    "    workload_identity_provider: ${google_iam_workload_identity_pool_provider.github[0].name}",
    "    service_account: ${google_service_account.ci[0].email}",
  ]) : "GitHub OIDC disabled"
}
