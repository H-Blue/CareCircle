"""Prepare the small paid Oracle NoSQL account table and Twilio Verify service.

Uses the existing private account configuration. Does not send messages, create
user accounts, change recipient permissions, or replace the backend VM.
"""
import json
from pathlib import Path
import sys
import time

import oci
from twilio.rest import Client

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Server"))
from server import load_environment
import os


def main():
    env = ROOT / "Server/.env"
    load_environment(env)
    config = oci.config.from_file(str(Path.home() / ".oci/encircle/config"))
    state_file = Path.home() / ".oci/encircle/cloud-state.json"
    state = json.loads(state_file.read_text())
    client = oci.nosql.NosqlClient(config)
    def tables():
        return [t for t in client.list_tables(compartment_id=state["compartment"]).data.items if t.name == "EncircleUsers"]
    rows = tables()
    if not rows:
        client.create_table(oci.nosql.models.CreateTableDetails(name="EncircleUsers", compartment_id=state["compartment"],
            ddl_statement="CREATE TABLE EncircleUsers (id STRING, data JSON, PRIMARY KEY (id))",
            table_limits=oci.nosql.models.TableLimits(max_read_units=256, max_write_units=128,
                max_storage_in_g_bs=1, capacity_mode="PROVISIONED"), is_auto_reclaimable=False))
    for _ in range(30):
        rows = tables()
        if rows and rows[0].lifecycle_state == "ACTIVE": break
        time.sleep(2)
    if not rows or rows[0].lifecycle_state != "ACTIVE":
        raise RuntimeError("The user table is not active yet. Check Oracle work requests before retrying.")
    table = client.get_table(rows[0].id).data
    if table.table_limits.capacity_mode != "PROVISIONED" or table.table_limits.max_read_units < 256 or table.table_limits.max_write_units < 128:
        client.update_table(rows[0].id, oci.nosql.models.UpdateTableDetails(compartment_id=state["compartment"],
            table_limits=oci.nosql.models.TableLimits(max_read_units=256, max_write_units=128,
                max_storage_in_g_bs=1, capacity_mode="PROVISIONED")))
    for _ in range(30):
        table = client.get_table(rows[0].id).data
        if table.table_limits.max_read_units >= 256 and table.table_limits.max_write_units >= 128: break
        time.sleep(2)
    else: raise RuntimeError("Oracle has not applied the account capacity update. Check it before deployment.")
    state["users_table"] = rows[0].id
    state_file.write_text(json.dumps(state, indent=2)); state_file.chmod(0o600)
    twilio = Client(os.environ["TWILIO_ACCOUNT_SID"], os.environ["TWILIO_AUTH_TOKEN"])
    services = [s for s in twilio.verify.v2.services.list(limit=50) if s.friendly_name == "Encircle sign in"]
    service = services[0] if services else twilio.verify.v2.services.create(friendly_name="Encircle sign in",
        code_length=6, lookup_enabled=True, do_not_share_warning_enabled=True)
    updates = {"ENCIRCLE_USERS_TABLE": rows[0].id, "TWILIO_VERIFY_SERVICE_SID": service.sid}
    lines = [line for line in env.read_text().splitlines() if line.partition("=")[0] not in updates]
    env.write_text("\n".join(lines + [k + "=" + v for k, v in updates.items()]) + "\n"); env.chmod(0o600)
    print("Oracle account database and Twilio Verify prepared. No verification texts sent.")


if __name__ == "__main__": main()
