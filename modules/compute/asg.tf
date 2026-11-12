locals {
  # 512 MiB floor: boot headroom above The Lounge's ~200MB idle footprint
  # plus the 1G swap file, not steady-state sizing. Nitro-only is a hard
  # requirement: user_data finds the data volume by NVMe controller serial
  # and the launch template sets ebs_optimized = true, neither of which
  # works on Xen. Allow-lists stop at .small -- The Lounge never needs more.
  # The rightsize watchdog replaces the instance when the cheapest eligible
  # pool costs at most 75% of its type's Spot price, since
  # price-capacity-optimized only picks a pool at launch. The eligible types
  # come from the ASG's own requirements, so the allow-lists are the only list.
  derived_instance_requirements = {
    vcpu_min             = 1
    memory_mib_min       = 512
    allowed_types_arm64  = ["t4g.nano", "t4g.micro", "t4g.small"]
    allowed_types_x86_64 = ["t3.nano", "t3a.nano", "t3.micro", "t3a.micro", "t3.small", "t3a.small"]
  }

  instance_requirements = (
    var.instance_requirements != null
    ? var.instance_requirements
    : local.derived_instance_requirements
  )
}

resource "aws_autoscaling_group" "this" {
  name = local.name_env

  # Never launch before the instance role's policy is current: Terraform
  # infers no ordering from the launch template to the policy on its own.
  # Load-bearing during a data-volume swap -- see iam.tf's AttachVolume
  # statement for why a stale policy wedges boot.
  depends_on = [aws_iam_role_policy.instance]

  # var.active is the sleep switch: 0 releases the instance while every
  # other resource (data volume, config bucket, last build artifact) stays
  # put, so flipping back to 1 self-heals to a serving site once the new
  # instance's converge timer ticks.
  min_size            = var.active ? 1 : 0
  max_size            = var.active ? 1 : 0
  desired_capacity    = var.active ? 1 : 0
  vpc_zone_identifier = [var.subnet_id]
  capacity_rebalance  = false

  mixed_instances_policy {
    launch_template {
      # Base spec is required, but both overrides set their own LT
      # explicitly, so this is only a fallback. Pointed at arm64 (cheaper
      # Graviton pools).
      launch_template_specification {
        launch_template_id = aws_launch_template.this["arm64"].id
        version            = aws_launch_template.this["arm64"].latest_version
      }

      # arm64 / Graviton. cpu_manufacturers pins the arch.
      override {
        launch_template_specification {
          launch_template_id = aws_launch_template.this["arm64"].id
          version            = aws_launch_template.this["arm64"].latest_version
        }
        instance_requirements {
          memory_mib {
            min = local.instance_requirements.memory_mib_min
          }
          vcpu_count {
            min = local.instance_requirements.vcpu_min
          }
          cpu_manufacturers      = ["amazon-web-services"]
          allowed_instance_types = local.instance_requirements.allowed_types_arm64
          burstable_performance  = "included"
        }
      }

      # x86_64 / Intel + AMD. Same vCPU/memory floor as arm64 so a Spot
      # fallout onto x86 lands on an equivalent box, not a pricier one.
      override {
        launch_template_specification {
          launch_template_id = aws_launch_template.this["x86_64"].id
          version            = aws_launch_template.this["x86_64"].latest_version
        }
        instance_requirements {
          memory_mib {
            min = local.instance_requirements.memory_mib_min
          }
          vcpu_count {
            min = local.instance_requirements.vcpu_min
          }
          cpu_manufacturers      = ["intel", "amd"]
          allowed_instance_types = local.instance_requirements.allowed_types_x86_64
          burstable_performance  = "included"
        }
      }
    }

    instances_distribution {
      spot_allocation_strategy                 = "price-capacity-optimized"
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = var.spot_enabled ? 0 : 100
    }
  }

  tag {
    key                 = "Name"
    value               = local.name
    propagate_at_launch = true
  }

  # The watchdogs' self-terminate call (thelounge-rightsize-watchdog.sh,
  # thelounge-health-watchdog.sh) is IAM-gated on aws:ResourceTag/Project ==
  # "thelounge" (iam.tf); this tag is what satisfies that condition.
  tag {
    key                 = "Project"
    value               = local.name
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }
}
