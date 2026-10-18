"""Live timer smoke test using temporary accounts without consent; never sends SMS."""
import json
import os
from pathlib import Path
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Server"))
from server import load_environment
from users import OracleDirectory, digest
from coordinator import OracleState
from visits import OracleObjects


def main():
    load_environment(ROOT / "Server/.env")
    os.environ["OCI_CONFIG_FILE"] = str(Path.home() / ".oci/encircle/config")
    os.environ["OCI_AUTH"] = "api_key"
    private = json.loads((Path.home() / ".oci/encircle/cloud-state.json").read_text())
    os.environ["ENCIRCLE_VISITS_BUCKET"] = private["visits_bucket"]
    accounts = OracleDirectory(); queue = OracleState(); objects = OracleObjects()
    uid, outsider, circle = [uuid.uuid4().hex for _ in range(3)]
    token, outside_token = [secrets.token_urlsafe(48) for _ in range(2)]
    visit = str(uuid.uuid4()).upper()
    def request(path, credential=token, payload=None, **fields):
        time.sleep(.6)
        url = private["endpoint"] + path
        if fields: url += "?" + urllib.parse.urlencode(fields)
        req = urllib.request.Request(url, data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Authorization": "Bearer " + credential, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=65) as r: return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e: return e.code, None
    if request("/health", credential=os.environ["ENCIRCLE_APP_TOKEN"])[0] != 200:
        raise RuntimeError("Backend is not ready; no fixtures created.")
    def seed(data):
        for user, credential, phone in ((uid, token, "+15555550126"), (outsider, outside_token, "+15555550127")):
            data["users"][user] = {"id": user, "name": "Synthetic transport tester", "phone": phone}
            data["sessions"][digest(credential)] = {"user_id": user, "expires": time.time() + 600}
        data["circles"][circle] = {"id": circle, "name": "Temporary transport test", "patient_name": "Synthetic Jessie",
            "invite_code": secrets.token_hex(8).upper(), "presentation_enabled": True, "members": {uid: "leader"}}
    accounts.update(seed)
    try:
        assert request("/visits/save", payload={"circle_id": circle, "visit": {"id": visit,
            "date": time.time() - 978307200, "duration": 2, "complete": True, "lines": [], "partial": ""}})[0] == 200
        start = time.time()
        code, event = request("/visits/transport/schedule", payload={"circle_id": circle, "visit_id": visit})
        assert code == 200 and event["scheduled"] and event["due_at"] >= start + 20
        assert request("/visits/transport/status", credential=outside_token, circle_id=circle)[0] == 403
        assert request("/visits/transport/status", circle_id=circle)[1]["messages"] == []
        _, repeated = request("/visits/transport/schedule", payload={"circle_id": circle, "visit_id": visit})
        assert repeated["due_at"] == event["due_at"]
        time.sleep(max(0, event["due_at"] - time.time() - 2))
        before = request("/visits/transport/status", circle_id=circle)[1]
        if time.time() < event["due_at"]: assert before["messages"] == []
        status = None
        for _ in range(30):
            _, status = request("/visits/transport/status", circle_id=circle)
            if status and len(status["messages"]) == 3: break
            time.sleep(1)
        assert status and len(status["messages"]) == 3
        assert all(m["state"] == "pending" and not m.get("response") for m in status["messages"])
        assert all("Synthetic Jessie" in m["body"] and "STOP" in m["body"] for m in status["messages"])
        assert not any(m["consent"] for m in status["members"])
        print("Live 20-second delay, persistent retry, appointment drafting, circle privacy and blocked-without-consent checks passed. No SMS sent.")
    finally:
        # Stop future processing before removing synthetic identities or private objects.
        accounts.update(lambda data: data["circles"][circle].update(presentation_enabled=False) if circle in data["circles"] else None)
        def clear(state):
            data = state.get("circle_transport", {})
            for collection in ("events", "jobs"):
                data[collection] = {k: v for k, v in data.get(collection, {}).items() if v["circle_id"] != circle}
            data["rides"] = {k: v for k, v in data.get("rides", {}).items() if not k.startswith(circle + "/")}
        queue.update(clear)
        def remove(data):
            data["circles"].pop(circle, None)
            for user, credential in ((uid, token), (outsider, outside_token)):
                data["users"].pop(user, None); data["sessions"].pop(digest(credential), None)
        accounts.update(remove)
        import oci
        versions = oci.pagination.list_call_get_all_results(objects.client.list_object_versions, objects.namespace,
            objects.bucket, prefix="circles/" + circle + "/").data
        for version in versions:
            objects.client.delete_object(objects.namespace, objects.bucket, version.name, version_id=version.version_id)
        print("Temporary synthetic identities, current queue entries and private visit object versions removed.")


if __name__ == "__main__": main()
