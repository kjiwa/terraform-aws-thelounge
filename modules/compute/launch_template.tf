locals {
  # Architectures the ASG provisions across. Keys flow through to the launch
  # templates (one per arch) and the mixed-instances overrides in asg.tf.
  architectures = toset(["arm64", "x86_64"])
}

resource "aws_launch_template" "this" {
  for_each = local.architectures

  # name_prefix is ForceNew; keeping it arch-independent means a change to
  # shared fields never collides the two templates' names. Tell them apart
  # by architecture/image_id in the console.
  name_prefix   = "${local.name_env}-"
  image_id      = local.ami_ids[each.key]
  ebs_optimized = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [var.app_sg_id]

  # No key_name: the network module's EICE pushes ephemeral keys per
  # session, so a static key pair would be a standing credential with no
  # break-glass use to justify it.

  # AL2023's root device is /dev/xvda regardless of architecture. The stock
  # image's own (unencrypted, default-size) root volume is overridden here
  # for gp3/encrypted/8GB.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region            = var.region
    ebs_volume_id     = var.ebs_volume_id
    eip_allocation_id = var.eip_allocation_id != null ? var.eip_allocation_id : ""
    config_bucket     = var.config_bucket_name
    asg_name          = local.name_env
    # Applied as a systemd timer drop-in at boot; see configure_rightsize_timer.
    rightsize_schedule = var.rightsize_schedule
    # The watchdog's churn bound; consumed from instance.env.
    rightsize_min_uptime_hours = var.rightsize_min_uptime_hours
  }))

  # The Lounge runs directly under systemd (no container hop), so the
  # default single hop is enough for user_data and every watchdog's IMDSv2
  # calls.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Detailed (1-minute) monitoring costs extra; the watchdogs poll app and
  # instance health themselves on their own timers, so it buys nothing here.
  monitoring {
    enabled = false
  }

  credit_specification {
    cpu_credits = var.cpu_credits
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = local.name
      Project = local.name
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name}-root"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
