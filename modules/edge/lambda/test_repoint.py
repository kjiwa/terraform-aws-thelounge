import copy

import pytest

ENV = {
    "REGION": "us-east-1",
    "ACCOUNT_ID": "123456789012",
    "DISTRIBUTION_ID": "EDIST",
    "AWS_DEFAULT_REGION": "us-east-1",
}
INSTANCE = "i-0abc"
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

    def __init__(self, chat_id, status_id, arn, instance=INSTANCE):
        self.config = {
            "Origins": {
                "Items": [
                    {"Id": "thelounge", "VpcOriginConfig": {"VpcOriginId": chat_id}},
                    {
                        "Id": "thelounge-status",
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

    def get_distribution_config(self, Id):
        return {"DistributionConfig": copy.deepcopy(self.config), "ETag": "e"}

    def update_distribution(self, Id, IfMatch, DistributionConfig):
        self.config = DistributionConfig
        self.updates += 1

    def get_distribution(self, Id):
        return {"Distribution": {"Status": "Deployed"}}

    def get_vpc_origin(self, Id):
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
        items = [{"Id": vid, "Name": o["Name"]} for vid, o in self.origins.items()]
        return {"VpcOriginList": {"Items": items}}

    def delete_vpc_origin(self, Id, IfMatch):
        del self.origins[Id]


def install(monkeypatch, repoint, cloudfront, ssm):
    monkeypatch.setattr(repoint, "cloudfront", cloudfront)
    monkeypatch.setattr(repoint, "ssm", ssm)
    monkeypatch.setattr(repoint, "_running_instance_id", lambda: INSTANCE)


CHAT = "/thelounge/edge/vpc-origin/chat"
STATUS = "/thelounge/edge/vpc-origin/status"


def test_publishes_new_ids_after_repoint(monkeypatch, repoint):
    cloudfront = FakeCloudFront(
        "vo_old_chat",
        "vo_old_status",
        "arn:aws:ec2:us-east-1:123456789012:instance/i-0old",
        instance="i-0old",
    )
    ssm = FakeSsm({CHAT: "vo_old_chat", STATUS: "vo_old_status"})
    install(monkeypatch, repoint, cloudfront, ssm)

    repoint.handler({}, None)

    assert cloudfront.updates == 1
    assert ssm.values == {
        CHAT: "vo_new_thelounge-i-0abc",
        STATUS: "vo_new_thelounge-i-0abc-status",
    }


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
