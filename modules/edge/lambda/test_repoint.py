import copy
import datetime
import pathlib
import re

import pytest

ENV = {
    "REGION": "us-east-1",
    "ACCOUNT_ID": "123456789012",
    "DISTRIBUTION_ID": "EDIST",
    "AWS_DEFAULT_REGION": "us-east-1",
}
INSTANCE = "i-0abc"
DNS = "ip-10-20-0-79.ec2.internal"
ARN = f"arn:aws:ec2:us-east-1:123456789012:instance/{INSTANCE}"


@pytest.fixture
def repoint(monkeypatch):
    for key, value in ENV.items():
        monkeypatch.setenv(key, value)
    import repoint

    return repoint


class ParameterNotFound(Exception):
    pass


class FakeSsm:
    class exceptions:
        ParameterNotFound = ParameterNotFound

    def __init__(self, values):
        self.values = dict(values)
        self.puts = []

    def get_parameter(self, Name):
        if Name not in self.values:
            raise ParameterNotFound()
        return {"Parameter": {"Value": self.values[Name]}}

    def put_parameter(self, Name, Value, Type, Overwrite):
        assert Type == "String" and Overwrite
        self.values[Name] = Value
        self.puts.append((Name, Value))


class FakeCloudFront:
    class exceptions:
        CannotDeleteEntityWhileInUse = type(
            "CannotDeleteEntityWhileInUse", (Exception,), {}
        )
        IllegalDelete = type("IllegalDelete", (Exception,), {})
        EntityNotFound = type("EntityNotFound", (Exception,), {})
        InvalidIfMatchVersion = type("InvalidIfMatchVersion", (Exception,), {})
        PreconditionFailed = type("PreconditionFailed", (Exception,), {})

    def __init__(self, chat_id, status_id, arn, instance=INSTANCE, domain=DNS):
        self.config = {
            "Origins": {
                "Items": [
                    {
                        "Id": "thelounge",
                        "DomainName": domain,
                        "VpcOriginConfig": {"VpcOriginId": chat_id},
                    },
                    {
                        "Id": "thelounge-status",
                        "DomainName": domain,
                        "VpcOriginConfig": {"VpcOriginId": status_id},
                    },
                ]
            }
        }
        self.origins = {
            vid: {"Name": name, "Arn": arn, "Status": "Deployed"}
            for vid, name in (
                (chat_id, f"thelounge-{instance}"),
                (status_id, f"thelounge-{instance}-status"),
            )
        }
        self.updates = 0
        self.modified = {}
        self.vanished = set()

    def get_distribution_config(self, Id):
        return {"DistributionConfig": copy.deepcopy(self.config), "ETag": "e"}

    def update_distribution(self, Id, IfMatch, DistributionConfig):
        self.config = DistributionConfig
        self.updates += 1

    def get_distribution(self, Id):
        return {"Distribution": {"Status": "Deployed"}}

    def get_vpc_origin(self, Id):
        if Id in self.vanished:
            raise self.exceptions.EntityNotFound()
        o = self.origins[Id]
        return {
            "ETag": "e",
            "VpcOrigin": {
                "Status": o["Status"],
                "VpcOriginEndpointConfig": {"Name": o["Name"], "Arn": o["Arn"]},
            },
        }

    def create_vpc_origin(self, VpcOriginEndpointConfig):
        vid = "vo_new_" + VpcOriginEndpointConfig["Name"]
        self.origins[vid] = {
            "Name": VpcOriginEndpointConfig["Name"],
            "Arn": VpcOriginEndpointConfig["Arn"],
            "Status": "Deployed",
        }
        return {"VpcOrigin": {"Id": vid}}

    def list_vpc_origins(self, **kwargs):
        long_ago = datetime.datetime(2020, 1, 1, tzinfo=datetime.UTC)
        items = [
            {
                "Id": vid,
                "Name": o["Name"],
                "LastModifiedTime": self.modified.get(vid, long_ago),
            }
            for vid, o in self.origins.items()
        ]
        return {"VpcOriginList": {"Items": items}}

    def delete_vpc_origin(self, Id, IfMatch):
        del self.origins[Id]


def install(monkeypatch, repoint, cloudfront, ssm):
    monkeypatch.setattr(repoint, "cloudfront", cloudfront)
    monkeypatch.setattr(repoint, "ssm", ssm)
    monkeypatch.setattr(
        repoint,
        "_running_instance",
        lambda: {"InstanceId": INSTANCE, "PrivateDnsName": DNS},
    )


CHAT = "/thelounge/edge/vpc-origin/chat"
STATUS = "/thelounge/edge/vpc-origin/status"


def test_publishes_new_ids_after_repoint(monkeypatch, repoint):
    cloudfront = FakeCloudFront(
        "vo_old_chat",
        "vo_old_status",
        "arn:aws:ec2:us-east-1:123456789012:instance/i-0old",
        instance="i-0old",
        domain="ip-10-20-0-198.ec2.internal",
    )
    ssm = FakeSsm({CHAT: "vo_old_chat", STATUS: "vo_old_status"})
    install(monkeypatch, repoint, cloudfront, ssm)

    repoint.handler({}, None)

    assert cloudfront.updates == 1
    assert ssm.values == {
        CHAT: "vo_new_thelounge-i-0abc",
        STATUS: "vo_new_thelounge-i-0abc-status",
    }
    assert origin_domains(cloudfront) == [DNS, DNS]


def origin_domains(cloudfront):
    return [o["DomainName"] for o in cloudfront.config["Origins"]["Items"]]


def test_fast_path_rewrites_a_stale_domain_name(monkeypatch, repoint):
    cloudfront = FakeCloudFront(
        "vo_chat", "vo_status", ARN, domain="ip-10-20-0-198.ec2.internal"
    )
    install(monkeypatch, repoint, cloudfront, FakeSsm({}))

    repoint.handler({}, None)

    assert cloudfront.updates == 1
    assert origin_domains(cloudfront) == [DNS, DNS]
    assert [
        o["VpcOriginConfig"]["VpcOriginId"] for o in cloudfront.config["Origins"]["Items"]
    ] == ["vo_chat", "vo_status"]


def test_unchanged_path_syncs_differing_and_skips_missing_parameters(
    monkeypatch, repoint
):
    cloudfront = FakeCloudFront("vo_chat", "vo_status", ARN)
    ssm = FakeSsm({CHAT: "vo_stale"})
    install(monkeypatch, repoint, cloudfront, ssm)

    repoint.handler({}, None)

    assert cloudfront.updates == 0
    assert ssm.values == {CHAT: "vo_chat"}


def test_unchanged_path_skips_matching_parameters(monkeypatch, repoint):
    cloudfront = FakeCloudFront("vo_chat", "vo_status", ARN)
    ssm = FakeSsm({CHAT: "vo_chat", STATUS: "vo_status"})
    install(monkeypatch, repoint, cloudfront, ssm)

    repoint.handler({}, None)

    assert ssm.puts == []


def leaked_origin(cloudfront, vid, modified=None):
    cloudfront.origins[vid] = {
        "Name": "thelounge-i-0leak",
        "Arn": ARN,
        "Status": "Deployed",
    }
    if modified is not None:
        cloudfront.modified[vid] = modified


def test_sweep_deletes_an_old_unreferenced_origin(monkeypatch, repoint):
    cloudfront = FakeCloudFront("vo_chat", "vo_status", ARN)
    leaked_origin(cloudfront, "vo_leak")
    install(monkeypatch, repoint, cloudfront, FakeSsm({}))

    repoint.handler({}, None)

    assert "vo_leak" not in cloudfront.origins


def test_sweep_spares_an_origin_a_concurrent_run_may_still_attach(monkeypatch, repoint):
    cloudfront = FakeCloudFront("vo_chat", "vo_status", ARN)
    just_now = datetime.datetime.now(datetime.UTC)
    leaked_origin(cloudfront, "vo_fresh", modified=just_now)
    install(monkeypatch, repoint, cloudfront, FakeSsm({}))

    repoint.handler({}, None)

    assert "vo_fresh" in cloudfront.origins


@pytest.mark.parametrize("error", ["EntityNotFound", "InvalidIfMatchVersion"])
def test_sweep_tolerates_an_origin_deleted_underneath_it(monkeypatch, repoint, error):
    cloudfront = FakeCloudFront("vo_chat", "vo_status", ARN)
    leaked_origin(cloudfront, "vo_gone")
    leaked_origin(cloudfront, "vo_other")
    raised = getattr(cloudfront.exceptions, error)

    def racing_delete(Id, IfMatch):
        if Id == "vo_gone":
            raise raised()
        del cloudfront.origins[Id]

    cloudfront.delete_vpc_origin = racing_delete
    install(monkeypatch, repoint, cloudfront, FakeSsm({}))

    repoint.handler({}, None)

    assert "vo_other" not in cloudfront.origins


def test_sweep_tolerates_an_origin_that_vanishes_before_its_etag_read(
    monkeypatch, repoint
):
    cloudfront = FakeCloudFront("vo_chat", "vo_status", ARN)
    leaked_origin(cloudfront, "vo_gone")
    cloudfront.vanished.add("vo_gone")
    install(monkeypatch, repoint, cloudfront, FakeSsm({}))

    repoint.handler({}, None)


def test_worst_case_waits_fit_in_the_lambda_timeout(repoint):
    tf = pathlib.Path(__file__).parent.parent.joinpath("repoint_lambda.tf").read_text()
    timeout = int(re.search(r"^\s*timeout\s*=\s*(\d+)", tf, re.MULTILINE).group(1))

    worst_case = (
        2 * repoint.VPC_ORIGIN_DEPLOY_BUDGET_SECONDS
        + repoint.DISTRIBUTION_DEPLOY_BUDGET_SECONDS
    )

    assert worst_case < timeout
