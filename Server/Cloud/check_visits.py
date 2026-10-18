"""Admin-run live storage smoke test with temporary synthetic accounts only.

Never sends SMS, never accepts consent, never edits real circles. The private
Oracle administrator inserts temporary session hashes, exercises normal HTTPS
authorization, and removes exactly those fixtures and their object versions.
"""
import hashlib
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

import oci

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Server"))
from server import load_environment
from users import OracleDirectory, digest


def main():
    load_environment(ROOT / "Server/.env")
    private = json.loads((Path.home() / ".oci/encircle/cloud-state.json").read_text())
    config = oci.config.from_file(str(Path.home() / ".oci/encircle/config"))
    os.environ["OCI_CONFIG_FILE"] = str(Path.home() / ".oci/encircle/config")
    os.environ["OCI_AUTH"] = "api_key"
    store = OracleDirectory()
    def request(path, token, payload=None, raw=None, **fields):
        url = private["endpoint"] + path
        if fields: url += "?" + urllib.parse.urlencode(fields)
        body = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
        req = urllib.request.Request(url, data=body, headers={"Authorization": "Bearer " + token,
            "Content-Type": "application/octet-stream" if raw is not None else "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=65) as r:
                data = r.read()
                return r.status, data if r.headers.get_content_type() == "application/octet-stream" else json.loads(data)
        except urllib.error.HTTPError as error:
            try: message = json.loads(error.read()).get("error", "")
            except ValueError: message = "Gateway response"
            if error.code not in (401, 403): print("Storage check response:", path, error.code, message, flush=True)
            return error.code, None
    status, _ = request("/health", os.environ["ENCIRCLE_APP_TOKEN"])
    if status != 200: raise RuntimeError("The backend is not ready; no fixtures were created.")
    ids = [uuid.uuid4().hex for _ in range(3)]
    tokens = [secrets.token_urlsafe(48) for _ in ids]
    circle = uuid.uuid4().hex; vid = str(uuid.uuid4()).upper()
    def seed(data):
        for index, (uid, token) in enumerate(zip(ids, tokens)):
            data["users"][uid] = {"id": uid, "name": "Synthetic storage tester", "phone": "+1555555012" + str(index)}
            data["sessions"][digest(token)] = {"user_id": uid, "expires": time.time() + 600}
        data["circles"][circle] = {"id": circle, "name": "Temporary storage test", "patient_name": "Synthetic patient",
            "invite_code": secrets.token_hex(8).upper(), "members": {ids[0]: "leader", ids[1]: "friend"}}
    store.update(seed)
    try:
        payload = {"circle_id": circle, "visit": {"id": vid, "date": time.time() - 978307200, "duration": 2,
            "complete": True, "partial": "", "lines": [{"id": str(uuid.uuid4()).upper(), "elapsed": 0,
            "text": "This is a synthetic test transcript. The clinician says to arrange a check-in in two weeks."}]}}
        assert request("/visits/save", tokens[0], payload)[0] == 200
        assert request("/visits/detail", tokens[1], circle_id=circle, visit_id=vid)[0] == 200
        assert request("/visits/detail", tokens[2], circle_id=circle, visit_id=vid)[0] == 403
        audio = b"synthetic-storage-probe-" * 50000
        sha = hashlib.sha256(audio).hexdigest()
        spec = {"circle_id": circle, "visit_id": vid, "sha": sha, "bytes": len(audio)}
        status, started = request("/visits/audio/start", tokens[0], spec)
        assert status == 200
        chunk = started["chunk_size"]
        for index in range((len(audio) + chunk - 1) // chunk):
            assert request("/visits/audio/part", tokens[0], raw=audio[index * chunk:(index + 1) * chunk], circle_id=circle, visit_id=vid, sha=sha, index=index)[0] == 200
        assert request("/visits/audio/finish", tokens[0], spec)[0] == 200
        for _ in range(30):
            status, record = request("/visits/detail", tokens[1], circle_id=circle, visit_id=vid)
            if status == 200 and record["audio_ready"]: break
            time.sleep(1)
        assert record["audio_ready"]
        downloaded = b"".join(request("/visits/audio/part", tokens[1], circle_id=circle, visit_id=vid, index=index)[1] for index in range(record["audio_parts"]))
        assert hashlib.sha256(downloaded).hexdigest() == sha
        assert request("/visits/summary", tokens[0], {"circle_id": circle, "visit_id": vid})[0] == 200
        for _ in range(30):
            status, record = request("/visits/detail", tokens[1], circle_id=circle, visit_id=vid)
            if status == 200 and record["visit"].get("summary"): break
            time.sleep(1)
        assert record["visit"].get("summary")
        assert request("/visits/archive", tokens[1], {"circle_id": circle, "visit_id": vid, "archived": True})[0] == 200
        assert request("/visits", tokens[1], circle_id=circle)[1]["visits"][0]["visit"]["archived"]
        assert not request("/visits", tokens[0], circle_id=circle)[1]["visits"][0]["visit"]["archived"]
        assert request("/users/circles/leave", tokens[1], {"circle_id": circle})[0] == 200
        assert request("/visits/audio/part", tokens[1], circle_id=circle, visit_id=vid, index=0)[0] == 403
        assert request("/visits/delete", tokens[0], {"circle_id": circle, "visit_id": vid})[0] == 200
        print("Live Oracle sharing, audio checksum, summary, personal archive and membership-revocation checks passed.")
    finally:
        def remove(data):
            data["circles"].pop(circle, None)
            for uid, token in zip(ids, tokens):
                data["users"].pop(uid, None); data["sessions"].pop(digest(token), None)
        store.update(remove)
        objects = oci.object_storage.ObjectStorageClient(config)
        namespace, bucket = private["coordinator_namespace"], private["visits_bucket"]
        for prefix in ["circles/" + circle + "/"] + ["preferences/" + uid + "/" for uid in ids]:
            versions = oci.pagination.list_call_get_all_results(objects.list_object_versions, namespace, bucket, prefix=prefix).data
            for version in versions:
                if not version.name.startswith(prefix): raise RuntimeError("Unsafe test cleanup prefix")
                objects.delete_object(namespace, bucket, version.name, version_id=version.version_id)
        print("Temporary synthetic accounts, sessions, circle, and stored object versions removed.")


if __name__ == "__main__": main()
