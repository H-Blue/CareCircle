"""Local simulator-only account fixture. Never deployed or used with real phones."""
import sys
from pathlib import Path
from http.server import ThreadingHTTPServer
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Server"))
from server import make_handler
from users import Accounts, MemoryDirectory

verifier = Mock()
verifier.send.side_effect = lambda phone: "VE-local-" + phone
verifier.check.side_effect = lambda sid, code: code == "654321"
server = ThreadingHTTPServer(("127.0.0.1", 8799), make_handler(Mock(), "local-fixture-only", accounts=Accounts(MemoryDirectory(), verifier)))
print("Local account fixture ready; no provider or cloud connection.", flush=True)
server.serve_forever()
