# Minimal deployment

Hosted zone, cost budget, and audit trail from [terraform-aws-keel](https://github.com/kjiwa/terraform-aws-keel), plus The Lounge with three required inputs.

```hcl
module "thelounge" {
  source = "git::https://github.com/kjiwa/terraform-aws-thelounge.git?ref=v1.1.0"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  domain_name = "example.org"
  zone_id     = module.dns.zone_ids["example.org"]
  alert_email = "you@example.org"
}
```

The module needs an `aws.us_east_1` provider alias and an existing public Route 53 hosted zone for `domain_name`. `main.tf` creates the zone with keel's `dns` module. The `audit` module logs the module's delivery bucket.
