"""Local simulator-only account fixture. Never deployed or used with real phones."""
import sys
from pathlib import Path
from http.server import ThreadingHTTPServer
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Server"))
from server import make_handler
from visits import CloudVisits, MemoryObjects
from users import Accounts, MemoryDirectory

verifier = Mock()
verifier.send.side_effect = lambda phone: "VE-local-" + phone
verifier.check.side_effect = lambda sid, code: code == "654321"
accounts = Accounts(MemoryDirectory(), verifier)
chat = Mock(); chat.chat.return_value = "Your scan showed no broken bone. Arrange a check-in in two weeks."
cloud = CloudVisits(accounts, MemoryObjects(), chat)
server = ThreadingHTTPServer(("127.0.0.1", 8799), make_handler(chat, "local-fixture-only", accounts=accounts, cloud_visits=cloud))
print("Local account fixture ready; no provider or cloud connection.", flush=True)
server.serve_forever()
