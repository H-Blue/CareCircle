"""Build and launch the iPhone simulator app against the private local Oracle bridge."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

from server import load_environment


def main():
    root = Path(__file__).resolve().parent.parent
    load_environment(root / "Server/.env")
    token = os.environ.get("CARECIRCLE_APP_TOKEN", "")
    if len(token) < 32:
        raise SystemExit("Configure Server/.env first. See Server/README.md.")
    port = int(os.environ.get("CARECIRCLE_PORT", "8787"))
    address = f"http://localhost:{port}"

    def ready():
        request = urllib.request.Request(address + "/health", headers={"Authorization": "Bearer " + token})
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status == 200
        except urllib.error.HTTPError as error:
            raise SystemExit(f"An existing server on port {port} rejected the connection ({error.code}).")
        except (urllib.error.URLError, TimeoutError):
            return False

    if not ready():
        log = Path(tempfile.gettempdir()) / "carecircle-development-server.log"
        with log.open("a") as output:
            subprocess.Popen([sys.executable, str(root / "Server/server.py")], cwd=root,
                             stdout=output, stderr=output, start_new_session=True)
        for _ in range(20):
            if ready():
                break
            time.sleep(0.25)
        else:
            raise SystemExit(f"The bridge could not start. Check {log}.")

    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    iphones = [device for runtime in devices["devices"].values() for device in runtime
               if device["name"].startswith("iPhone")]
    if not iphones:
        raise SystemExit("Install an iPhone simulator runtime in Xcode first.")
    device = next((device for device in iphones if device["state"] == "Booted"), iphones[-1])
    if device["state"] != "Booted":
        subprocess.run(["xcrun", "simctl", "boot", device["udid"]], check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], check=True)
    log = root / "build/simulator-build.log"
    log.parent.mkdir(exist_ok=True)
    print("Building Care Circle…", flush=True)
    with log.open("w") as output:
        result = subprocess.run(["xcodebuild", "-project", str(root / "CareCircle.xcodeproj"),
                                 "-scheme", "CareCircle", "-configuration", "Debug", "-sdk", "iphonesimulator",
                                 "-derivedDataPath", str(root / "build"), "CODE_SIGNING_ALLOWED=NO", "build"],
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f"Build failed. Check {log}.")
    app = root / "build/Build/Products/Debug-iphonesimulator/CareCircle.app"
    subprocess.run(["xcrun", "simctl", "install", device["udid"], str(app)], check=True)
    # These values go directly to the simulator process environment, never command-line arguments or logs.
    launch_environment = os.environ.copy()
    launch_environment["SIMCTL_CHILD_CARECIRCLE_SERVER_ADDRESS"] = address
    launch_environment["SIMCTL_CHILD_CARECIRCLE_CONNECTION_TOKEN"] = token
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", device["udid"],
                    "com.harryhutchins.carecircle"], env=launch_environment, check=True)
    print(f"Care Circle is running on {device['name']}, connected to the local Oracle bridge.")


if __name__ == "__main__":
    main()
