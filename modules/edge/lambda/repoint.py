"""Reconciles thelounge's CloudFront distribution against the ASG's running instance.

The instance runs in an ASG of 1 on Spot, so its ARN changes on every Spot
reclaim or instance refresh -- and unlike an EIP, a VPC origin has no
mechanism of its own for following a replacement instance. This is the
zero-IPv4 stand-in for the EIP re-association a user_data script would do if
the instance still had a public IP to reassign.

Runs on a 1-minute schedule (repoint_lambda.tf) rather than reacting to the
ASG's launch event: a scheduled reconcile self-heals from any failure on the
next tick, where a one-shot event handler leaves the distribution stuck on a
dead origin until the next instance replacement. Each run is cheap when
nothing has changed (a handful of read-only calls) and idempotent under
overlapping retries.

CloudFront's UpdateVpcOrigin refuses to change a VPC origin's target ARN
while any distribution still references that origin
(CannotUpdateEntityWhileInUse), so this can't edit an existing VPC origin in
place. Instead, when a role's target has changed, it creates a new VPC
origin pointed at the new instance, repoints the distribution at it, waits
for that to deploy, then deletes the old one -- the same create-before-destroy
shape vpc_origin.tf uses for a full VPC-origin replacement, run out of band
by this Lambda instead of by Terraform.

After every distribution update, and on the unchanged path when they differ,
the live VPC origin id of each role is published to the SSM parameter named in
ROLES. Terraform's distribution reads those parameters, so it never reverts an
origin this Lambda moved (vpc_origin.tf, cloudfront.tf).

CreateVpcOrigin also authorizes the caller against the origin's target
itself, requiring ec2:DescribeInstances, ec2:DescribeInternetGateways,
elasticloadbalancing:DescribeLoadBalancers, and
elasticloadbalancing:DescribeListeners in addition to the cloudfront:*
actions -- true even for an EC2-instance target, not just an ALB/NLB one.
Missing any of these produces a bare AccessDenied with no other symptom (see
repoint_lambda.tf's IAM policy).

--- Two origins, one instance ---

The instance backs two VPC origins against the same ARN: chat on :9000
(Terraform's aws_cloudfront_vpc_origin.this) and the status page on :9001
(aws_cloudfront_vpc_origin.status, see thelounge-status.py for what that
serves). Both are reconciled here, matched to the distribution's origins by
Origin.Id ("thelounge" / "thelounge-status" -- exactly what cloudfront.tf's
locals.origin_id / locals.status_origin_id set), not by port or position:
the Id is already on the distribution config, so this needs no extra lookup
to know which origin is which.

Chat is the load-bearing path -- a repoint failure there means the site is
unreachable, caught only by the availability canary's alarm a few minutes
later. Status going stale means a dashboard shows an old instance's data for
a while. That asymmetry drives two rules, both enforced in _repoint_role and
handler():

  1. A failure repointing status (create error, deploy timeout, whatever)
     is caught, logged, and never allowed to abort or delay chat's own
     repoint or the distribution update that carries it.
  2. VPC origins are capped at 25 per account (a hard AWS quota), and this
     now spends two per instance plus short-lived duplicates mid-repoint.
     If the sweep below ever missed a leaked origin, repeated Spot
     reclaims would accumulate origins toward that ceiling -- and once hit,
     CreateVpcOrigin fails outright, which would stop CHAT from following a
     replacement, not just status. So only the status role ever checks
     remaining quota before creating; chat always attempts, unconditionally,
     for whatever quota is left. A quota-starved status origin just goes
     stale until the account has headroom again -- see
     VPC_ORIGIN_QUOTA_SAFEGUARD below.

It never touches a VPC origin this Lambda didn't create itself: only names
starting with "thelounge-i-" (both roles' generated names take this form --
see ROLES) are swept. Terraform's two tracked VPC origins only seed the SSM
parameters, then sit unreferenced and free after each origin's first repoint.
"""

import datetime
import json
import os
import time

import boto3

REGION = os.environ["REGION"]
ACCOUNT_ID = os.environ["ACCOUNT_ID"]
DISTRIBUTION_ID = os.environ["DISTRIBUTION_ID"]

# CloudFront's own deploy times dominate here (a VPC origin took ~2 minutes
# to reach Deployed in practice; AWS documents 15 minutes as the worst
# case). Both roles' VPC origin waits plus the distribution wait run
# sequentially and must sum to less than the Lambda's timeout
# (repoint_lambda.tf; test_repoint.py asserts it). A run that exceeds its
# budget gives up and the next scheduled tick resumes from the origin it
# created, found by name.
VPC_ORIGIN_DEPLOY_BUDGET_SECONDS = 300
DISTRIBUTION_DEPLOY_BUDGET_SECONDS = 240
POLL_INTERVAL_SECONDS = 5

# An unreferenced origin younger than this may belong to a concurrent run
# that has not attached it yet, so the sweep leaves it alone. Exceeds the
# Lambda's timeout, the longest a run can hold one.
SWEEP_GRACE_SECONDS = 900

# See the module docstring's "Two origins, one instance" section. 20 leaves
# five slots of headroom under the 25-per-account quota for the
# create-before-delete overlap of both roles across a single tick.
VPC_ORIGIN_QUOTA_SAFEGUARD = 20

# Origin roles. name_suffix feeds the generated VPC origin's Name
# (thelounge-<instance-id> / thelounge-<instance-id>-status); both forms
# start with "thelounge-i-" (every EC2 instance id does), so
# _sweep_leaked_origins' single prefix filter still catches both.
ROLES = (
    {
        "role": "chat",
        "origin_id": "thelounge",
        "name_suffix": "",
        "ssm_parameter": "/thelounge/edge/vpc-origin/chat",
    },
    {
        "role": "status",
        "origin_id": "thelounge-status",
        "name_suffix": "-status",
        "ssm_parameter": "/thelounge/edge/vpc-origin/status",
    },
)

cloudfront = boto3.client("cloudfront")
ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")


def _wait_deployed(get_status, budget_seconds):
    deadline = time.monotonic() + budget_seconds
    status = get_status()
    while status != "Deployed" and time.monotonic() < deadline:
        time.sleep(POLL_INTERVAL_SECONDS)
        status = get_status()
    return status


def _running_instance():
    # Mirrors the aws_instances filter in vpc_origin.tf. Newest launch wins
    # if a replacement briefly leaves two instances running.
    reservations = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Project", "Values": ["thelounge"]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )["Reservations"]
    instances = [i for r in reservations for i in r["Instances"]]
    if not instances:
        return None
    return max(instances, key=lambda i: i["LaunchTime"])


def _find_vpc_origin_id_by_name(name):
    # No boto3 paginator exists for list_vpc_origins. IsTruncated/NextMarker
    # are documented as always present but come back absent (not merely
    # false/empty) on an untruncated response in practice, so check with
    # .get() rather than trust the documented shape.
    kwargs = {}
    while True:
        page = cloudfront.list_vpc_origins(**kwargs)
        for item in page["VpcOriginList"]["Items"]:
            if item["Name"] == name:
                return item["Id"]
        if not page["VpcOriginList"].get("IsTruncated"):
            return None
        kwargs["Marker"] = page["VpcOriginList"]["NextMarker"]


def _count_vpc_origins():
    count = 0
    kwargs = {}
    while True:
        page = cloudfront.list_vpc_origins(**kwargs)
        count += len(page["VpcOriginList"]["Items"])
        if not page["VpcOriginList"].get("IsTruncated"):
            return count
        kwargs["Marker"] = page["VpcOriginList"]["NextMarker"]


def _origin_by_id(distribution_config, origin_id):
    return next(
        (
            o
            for o in distribution_config["Origins"]["Items"]
            if o["Id"] == origin_id and "VpcOriginConfig" in o
        ),
        None,
    )


def _domain_name_stale(distribution_config, private_dns):
    origins = (_origin_by_id(distribution_config, r["origin_id"]) for r in ROLES)
    return bool(private_dns) and any(
        o is not None and o.get("DomainName") != private_dns for o in origins
    )


def _sweep_leaked_origins(keep_vpc_origin_ids):
    """Delete any per-instance origin (either role) the distribution no
    longer references.

    Called from every path through handler(), not just after a repoint: a
    delete attempt can lose to CannotDeleteEntityWhileInUse (the origin was
    still Deploying), EntityNotFound, InvalidIfMatchVersion or
    PreconditionFailed (a concurrent sweep got there first), or IllegalDelete (observed in production: overlapping
    invocations racing the same origin -- one invocation's delete moves it
    out of a deletable state before a second, concurrent invocation's own
    delete attempt on the same id reaches CloudFront; two origins per
    instance means each invocation now runs long enough, waiting on create,
    for several 1-minute-scheduled ticks to overlap it) or be skipped
    outright (repointed-pending-deploy), and the next tick may take the
    unchanged fast path indefinitely afterward. Sweeping unconditionally is
    what makes cleanup eventually consistent.
    """
    kwargs = {}
    now = datetime.datetime.now(datetime.UTC)
    while True:
        page = cloudfront.list_vpc_origins(**kwargs)
        for item in page["VpcOriginList"]["Items"]:
            if item["Id"] in keep_vpc_origin_ids or not item["Name"].startswith(
                "thelounge-i-"
            ):
                continue
            if (now - item["LastModifiedTime"]).total_seconds() < SWEEP_GRACE_SECONDS:
                continue
            try:
                etag = cloudfront.get_vpc_origin(Id=item["Id"])["ETag"]
                cloudfront.delete_vpc_origin(Id=item["Id"], IfMatch=etag)
                print(
                    json.dumps(
                        {"action": "swept-leaked-origin", "vpc_origin_id": item["Id"]}
                    )
                )
            except (
                cloudfront.exceptions.CannotDeleteEntityWhileInUse,
                cloudfront.exceptions.IllegalDelete,
                cloudfront.exceptions.EntityNotFound,
                cloudfront.exceptions.InvalidIfMatchVersion,
                cloudfront.exceptions.PreconditionFailed,
            ):
                pass
        if not page["VpcOriginList"].get("IsTruncated"):
            return
        kwargs["Marker"] = page["VpcOriginList"]["NextMarker"]


def _repoint_role(role, dist_config, new_arn, new_instance_id, allow_create):
    """Reconcile one origin role against dist_config (read-only -- the
    caller applies the result to a freshly-fetched config before writing)
    and return the VPC origin id this role should end up referenced by, or
    None if this role's origin isn't present in dist_config at all.

    Never raises. Every failure -- a missing origin, an unreachable VPC
    origin, a failed create, a deploy timeout -- is caught, logged, and
    treated as "leave this role on whatever it already had", which is
    exactly what makes a status failure incapable of blocking chat: see the
    module docstring.
    """
    origin = _origin_by_id(dist_config, role["origin_id"])
    if origin is None:
        print(
            json.dumps(
                {
                    "action": "origin-missing",
                    "role": role["role"],
                    "origin_id": role["origin_id"],
                }
            )
        )
        return None

    current_vpc_origin_id = origin["VpcOriginConfig"]["VpcOriginId"]
    try:
        current = cloudfront.get_vpc_origin(Id=current_vpc_origin_id)
        current_arn = current["VpcOrigin"]["VpcOriginEndpointConfig"]["Arn"]
    except Exception as exc:  # noqa: BLE001 -- see docstring: never raise out of here
        print(
            json.dumps(
                {
                    "action": "get-vpc-origin-failed",
                    "role": role["role"],
                    "error": str(exc),
                }
            )
        )
        return current_vpc_origin_id

    if current_arn == new_arn:
        return current_vpc_origin_id

    if not allow_create:
        print(
            json.dumps(
                {
                    "action": "quota-deferred",
                    "role": role["role"],
                    "vpc_origin_id": current_vpc_origin_id,
                }
            )
        )
        return current_vpc_origin_id

    new_name = f"thelounge-{new_instance_id}{role['name_suffix']}"
    try:
        new_vpc_origin_id = _find_vpc_origin_id_by_name(new_name)
        if new_vpc_origin_id is None:
            new_config = dict(current["VpcOrigin"]["VpcOriginEndpointConfig"])
            new_config["Name"] = new_name
            new_config["Arn"] = new_arn
            created = cloudfront.create_vpc_origin(VpcOriginEndpointConfig=new_config)
            new_vpc_origin_id = created["VpcOrigin"]["Id"]

        status = _wait_deployed(
            lambda: cloudfront.get_vpc_origin(Id=new_vpc_origin_id)["VpcOrigin"][
                "Status"
            ],
            VPC_ORIGIN_DEPLOY_BUDGET_SECONDS,
        )
        if status != "Deployed":
            raise TimeoutError(
                f"VPC origin {new_vpc_origin_id} did not reach Deployed (status={status})"
            )
    except Exception as exc:  # noqa: BLE001
        print(
            json.dumps(
                {"action": "repoint-failed", "role": role["role"], "error": str(exc)}
            )
        )
        return current_vpc_origin_id

    print(
        json.dumps(
            {
                "action": "repointed",
                "role": role["role"],
                "old_vpc_origin_id": current_vpc_origin_id,
                "new_vpc_origin_id": new_vpc_origin_id,
                "new_arn": new_arn,
            }
        )
    )
    return new_vpc_origin_id


def _publish_vpc_origin_ids(resolved):
    for role in ROLES:
        vpc_origin_id = resolved[role["role"]]
        if vpc_origin_id is None:
            continue
        try:
            stored = ssm.get_parameter(Name=role["ssm_parameter"])["Parameter"]["Value"]
        except ssm.exceptions.ParameterNotFound:
            continue
        if stored != vpc_origin_id:
            ssm.put_parameter(
                Name=role["ssm_parameter"],
                Value=vpc_origin_id,
                Type="String",
                Overwrite=True,
            )
            print(
                json.dumps(
                    {
                        "action": "published-origin-id",
                        "role": role["role"],
                        "vpc_origin_id": vpc_origin_id,
                    }
                )
            )


def handler(event, context):
    instance = _running_instance()
    if instance is None:
        print(json.dumps({"action": "no-running-instance"}))
        return
    instance_id = instance["InstanceId"]
    private_dns = instance["PrivateDnsName"]

    new_arn = f"arn:aws:ec2:{REGION}:{ACCOUNT_ID}:instance/{instance_id}"

    dist = cloudfront.get_distribution_config(Id=DISTRIBUTION_ID)
    dist_config = dist["DistributionConfig"]
    chat_role, status_role = ROLES

    orig_ids = {}
    for role in ROLES:
        origin = _origin_by_id(dist_config, role["origin_id"])
        orig_ids[role["role"]] = (
            origin["VpcOriginConfig"]["VpcOriginId"] if origin else None
        )

    # Chat always attempts, unconditionally, for whatever origin quota is
    # left. Only status backs off -- see VPC_ORIGIN_QUOTA_SAFEGUARD.
    chat_id = _repoint_role(
        chat_role, dist_config, new_arn, instance_id, allow_create=True
    )
    allow_status_create = _count_vpc_origins() < VPC_ORIGIN_QUOTA_SAFEGUARD
    status_id = _repoint_role(
        status_role, dist_config, new_arn, instance_id, allow_create=allow_status_create
    )

    resolved = {"chat": chat_id, "status": status_id}
    keep_ids = {vpc_origin_id for vpc_origin_id in resolved.values() if vpc_origin_id}

    if resolved == orig_ids and not _domain_name_stale(dist_config, private_dns):
        # Fast path: nothing to write, just two-to-four cheap read calls
        # above. Sweep still runs -- see _sweep_leaked_origins' docstring
        # for why that must not be conditional on a repoint having happened.
        _sweep_leaked_origins(keep_ids)
        _publish_vpc_origin_ids(resolved)
        print(
            json.dumps(
                {"action": "unchanged", "vpc_origin_ids": resolved, "arn": new_arn}
            )
        )
        return

    # Re-fetch immediately before writing, and apply the resolved ids to
    # THIS fresh copy rather than the one read at the top: either role's own
    # create-and-wait can take minutes, and an overlapping run may have
    # already moved the distribution in the meantime.
    fresh = cloudfront.get_distribution_config(Id=DISTRIBUTION_ID)
    fresh_config = fresh["DistributionConfig"]
    for role in ROLES:
        fresh_origin = _origin_by_id(fresh_config, role["origin_id"])
        if fresh_origin is None:
            continue
        # Not used for routing, but Terraform manages it from the instance's
        # private DNS name; leaving it stale makes every replacement a plan
        # diff. Written for every role so a skipped role cannot keep the fast
        # path from applying.
        if private_dns:
            fresh_origin["DomainName"] = private_dns
        vpc_origin_id = resolved[role["role"]]
        if vpc_origin_id is not None:
            fresh_origin["VpcOriginConfig"]["VpcOriginId"] = vpc_origin_id

    cloudfront.update_distribution(
        Id=DISTRIBUTION_ID, IfMatch=fresh["ETag"], DistributionConfig=fresh_config
    )
    _publish_vpc_origin_ids(resolved)

    status = _wait_deployed(
        lambda: cloudfront.get_distribution(Id=DISTRIBUTION_ID)["Distribution"][
            "Status"
        ],
        DISTRIBUTION_DEPLOY_BUDGET_SECONDS,
    )
    if status != "Deployed":
        # The repoint already took effect (CloudFront serves the new
        # origin(s) before the distribution's Status flips back to
        # Deployed); the next scheduled tick sweeps once deploy catches up.
        print(
            json.dumps(
                {"action": "repointed-pending-deploy", "vpc_origin_ids": resolved}
            )
        )
        return

    _sweep_leaked_origins(keep_ids)
    print(
        json.dumps(
            {"action": "repointed", "vpc_origin_ids": resolved, "new_arn": new_arn}
        )
    )
