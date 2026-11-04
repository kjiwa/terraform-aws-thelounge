output "origins" {
  description = "CloudFront origins for the distribution: the shell bucket and the status Lambda (modules/edge status_origins)."
  value       = module.core.origins
}

output "behaviors" {
  description = "CloudFront ordered cache behaviors for the distribution (modules/edge status_behaviors)."
  value       = module.core.behaviors
}
