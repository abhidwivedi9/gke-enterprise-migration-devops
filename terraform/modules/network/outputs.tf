output "network_name" {
  description = "VPC name, consumed by the gke module."
  value       = google_compute_network.vpc.name
}

output "network_id" {
  value = google_compute_network.vpc.id
}

output "subnet_name" {
  description = "Subnet name, consumed by the gke module."
  value       = google_compute_subnetwork.subnet.name
}

output "subnet_self_link" {
  value = google_compute_subnetwork.subnet.self_link
}

output "pods_range_name" {
  description = "Secondary range name GKE uses for pod IPs."
  value       = "${var.name_prefix}-pods"
}

output "services_range_name" {
  description = "Secondary range name GKE uses for ClusterIPs."
  value       = "${var.name_prefix}-services"
}

output "node_tag" {
  description = "Network tag the GKE node pool must carry for the firewall rules to apply."
  value       = "${var.name_prefix}-node"
}
