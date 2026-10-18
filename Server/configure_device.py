"""Create an ignored, Debug-only connection profile for this developer's iPhone build."""
import hashlib
import json
import os
from pathlib import Path
import plistlib

from server import load_environment

root = Path(__file__).resolve().parent.parent
load_environment(root / "Server/.env")
state = json.loads((Path.home() / ".oci/encircle/cloud-state.json").read_text())
endpoint = state.get("endpoint")
if not endpoint or not endpoint.startswith("https://"):
    raise SystemExit("Deploy and verify the HTTPS endpoint first.")
token = os.environ["ENCIRCLE_APP_TOKEN"]
profile = {"serverAddress": endpoint, "connectionToken": token,
           "profileID": hashlib.sha256((endpoint + token).encode()).hexdigest()}
path = root / "Encircle/LocalConnection.plist"
path.write_bytes(plistlib.dumps(profile))
path.chmod(0o600)
print("Debug iPhone connection configured. The private profile is excluded from Git and Release builds.")
