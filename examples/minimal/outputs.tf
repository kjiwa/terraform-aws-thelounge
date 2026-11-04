output "name_servers" {
  description = "Name servers to set at the registrar for the domain."
  value       = module.dns.ns_records[var.domain_name]
}

output "url" {
  description = "Public HTTPS URL for the IRC client."
  value       = module.thelounge.url
}

output "thelounge" {
  description = "The module's outputs, as one object, for operator tooling that reads `terraform output -json`."
  value       = module.thelounge
}
