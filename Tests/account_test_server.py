"""Local simulator-only account fixture. Never deployed or used with real phones."""
import sys
import json
from pathlib import Path
from http.server import ThreadingHTTPServer
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Server"))
from server import make_handler
from visits import CloudVisits, MemoryObjects
from users import Accounts, MemoryDirectory
from coordinator import Coordinator, MemoryState
from circle_transport import CircleTransport

verifier = Mock()
verifier.send.side_effect = lambda phone: "VE-local-" + phone
verifier.check.side_effect = lambda sid, code: code == "654321"
accounts = Accounts(MemoryDirectory(), verifier)
chat = Mock(); chat.chat.return_value = "Your scan showed no broken bone. Arrange a check-in in two weeks."
cloud = CloudVisits(accounts, MemoryObjects(), chat)
sender = Mock(); sender.ready = False; sender.approval_status.return_value = False
sender.send_circle.side_effect = RuntimeError("Local fixture never sends messages")
coordinator = Coordinator(MemoryState(), sender)
coordinator.seed(json.loads((Path(__file__).resolve().parents[1] / "Server/fixtures/appointments.json").read_text()))
cloud.transport = CircleTransport(coordinator, accounts, cloud, planner=chat)
cloud.transport.start()
server = ThreadingHTTPServer(("127.0.0.1", 8799), make_handler(chat, "local-fixture-only", accounts=accounts, cloud_visits=cloud))
print("Local account fixture ready; no provider or cloud connection.", flush=True)
server.serve_forever()
