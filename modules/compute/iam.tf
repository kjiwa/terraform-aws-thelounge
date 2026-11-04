data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = local.name_env
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Name = local.name
  }
}

data "aws_iam_policy_document" "instance" {
  # EBS: read-only discovery.
  statement {
    sid       = "EBSDescribe"
    effect    = "Allow"
    actions   = ["ec2:DescribeVolumes"]
    resources = ["*"]
  }

  # EBS: attach/detach scoped to the data volume; instance side constrained
  # by tag.
  statement {
    sid     = "EBSAttachDetach"
    effect  = "Allow"
    actions = ["ec2:AttachVolume", "ec2:DetachVolume"]
    resources = [
      var.ebs_volume_arn,
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.name]
    }
  }

  # S3: instance config/units and app release artifacts, read-only -- the
  # delivery pipeline is the only writer to this bucket.
  statement {
    sid    = "S3ConfigAndArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${var.config_bucket_arn}/config/*",
      "${var.config_bucket_arn}/artifacts/*",
    ]
  }

  # S3: the one prefix the instance may write -- the converge timer's release
  # acknowledgement (deployed/current-<arch>.json), which scripts/deploy.sh
  # polls. Read access lets converge skip rewriting an unchanged acknowledgement.
  # The bucket is SSE-S3 with no CMK, so no KMS grant is needed.
  statement {
    sid       = "S3DeployAck"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.config_bucket_arn}/deployed/*"]
  }

  statement {
    sid       = "S3ConfigBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.config_bucket_arn]
  }

  # Only exists when the volume has a CMK (backup.mode = cross_account; see
  # storage/main.tf) -- the AWS-managed aws/ebs key grants account
  # principals implicitly, so a re-keyed volume with no matching grant here
  # fails to boot with CustomerKeyHasBeenRevoked (passing IAM on AttachVolume
  # isn't enough; EC2 still has to reach the key).
  dynamic "statement" {
    for_each = var.ebs_kms_key_arn != null ? [1] : []
    content {
      sid    = "KMSDataVolume"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
      ]
      resources = [var.ebs_kms_key_arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ec2.${var.region}.amazonaws.com"]
      }
    }
  }

  # CreateGrant unblocks the attach: EC2 creates a grant on the key (using
  # this role's credentials) to decrypt the volume's data key for the
  # attachment's life. GrantIsForAWSResource confines it to grants a service
  # creates for itself. Separate statement: kms:ViaService and
  # GrantIsForAWSResource can't share one condition block.
  dynamic "statement" {
    for_each = var.ebs_kms_key_arn != null ? [1] : []
    content {
      sid       = "KMSDataVolumeCreateGrant"
      effect    = "Allow"
      actions   = ["kms:CreateGrant"]
      resources = [var.ebs_kms_key_arn]
      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }

  # Rightsize watchdog's capacity gate: score the preferred Spot pools
  # before forcing a replacement. Read-only, account-level; not
  # resource-scopable.
  statement {
    sid       = "SpotPlacementScores"
    effect    = "Allow"
    actions   = ["ec2:GetSpotPlacementScores"]
    resources = ["*"]
  }

  # Self-replacement path: the watchdogs terminate the instance directly
  # rather than marking it Unhealthy (see thelounge-health-watchdog.sh).
  # Resource "*" since the instance ID is only known at runtime; the Project
  # tag condition (from the ASG's tag block) scopes this to the fleet's own
  # instances.
  statement {
    sid       = "SelfTerminate"
    effect    = "Allow"
    actions   = ["ec2:TerminateInstances"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [local.name]
    }
  }

  # Disk usage metric (thelounge-disk-metric.sh). PutMetricData is not
  # resource-scopable; the namespace condition limits it to this stack's own.
  statement {
    sid       = "PutDiskMetric"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["TheLounge"]
    }
  }

  # Only with enable_public_ipv4: user_data associates the Elastic IP at boot
  # (associate_eip). The instance side is constrained by tag, the address side
  # by allocation.
  dynamic "statement" {
    for_each = var.eip_allocation_id != null ? [1] : []
    content {
      sid     = "EIPAssociate"
      effect  = "Allow"
      actions = ["ec2:AssociateAddress"]
      resources = [
        "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:elastic-ip/${var.eip_allocation_id}",
        "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*",
      ]
      condition {
        test     = "StringEquals"
        variable = "aws:ResourceTag/Project"
        values   = [local.name]
      }
    }
  }

  # Only with the catchup feature: the Bedrock-calling gateway Lambda (the
  # instance has no IPv4 route to bedrock-runtime).
  dynamic "statement" {
    for_each = var.llm_gateway_function_arn != null ? [1] : []
    content {
      sid       = "InvokeLlmGateway"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = [var.llm_gateway_function_arn]
    }
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = local.name_env
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = local.name_env
  role = aws_iam_role.instance.name
}
