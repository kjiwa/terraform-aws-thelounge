variable "env" {
  description = "Environment name. Disambiguates this module's pipeline, IAM roles, and EventBridge rule if instantiated more than once in the same account; the bucket (already account-scoped by account ID) and the two CodeBuild projects (one per architecture, fixed names) do not vary by it."
  type        = string
}

variable "desired_state" {
  description = "Desired release, written verbatim (zipped as desired/desired.zip for the S3 source action) -- the pipeline's S3 source. Changing any field and applying is the deploy trigger: the object write fires the EventBridge rule that starts the pipeline. plugins are npm package specifiers (name or name@version) installed into bundle/packages by the build. plugin_configs maps a package name to the JSON the build writes as bundle/packages/<name>/config.json; omitted from desired.json while empty so an unused feature leaves the pipeline trigger untouched."
  type = object({
    thelounge_version = string
    node_version      = string
    plugins           = list(string)
    plugin_configs    = optional(map(any), {})
  })
}

variable "config_objects" {
  description = "Instance-side config and unit files, written to config/<key> (e.g. \"config.js\", \"users.json\", \"instance/thelounge-converge.sh\", \"instance/thelounge.service\"). Map key becomes the S3 key suffix under config/; map value is the object's content, written verbatim."
  type        = map(string)
}
