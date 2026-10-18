import json
import threading
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from unittest.mock import Mock

from server import make_handler
from users import Accounts, MemoryDirectory, UserError, digest


class AccountTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000000
        self.store = MemoryDirectory()
        self.provider = Mock()
        self.provider.send.side_effect = lambda phone: "VE" + phone
        self.provider.check.side_effect = lambda sid, code: code == "654321"
        self.accounts = Accounts(self.store, self.provider, clock=lambda: self.now)

    def login(self, phone="+15555550123", name="Demo Owner"):
        start = self.accounts.start(dict(phone=phone, name=name))
        return self.accounts.check(dict(challenge=start["challenge"], code="654321"))

    def create(self, token):
        return self.accounts.action(token, "/users/circles/create", dict(name="Demo circle", patient_name="Demo patient"))["circles"][0]

    def test_sign_in_requires_provider_approval_and_no_raw_tokens_stored(self):
        start = self.accounts.start(dict(phone="(555) 555-0123", name="Owner"))
        with self.assertRaises(UserError): self.accounts.check(dict(challenge=start["challenge"], code="000000"))
        self.assertFalse(self.store.data["users"])
        result = self.accounts.check(dict(challenge=start["challenge"], code="654321"))
        self.assertNotIn(result["token"], json.dumps(self.store.data))
        self.assertNotIn("654321", json.dumps(self.store.data))
        self.assertIn(digest(result["token"]), self.store.data["sessions"])
        self.assertEqual(result["user"]["phone"], "+15555550123")
        with self.assertRaises(UserError): self.accounts.check(dict(challenge=start["challenge"], code="654321"))

    def test_code_expiry_and_five_attempt_limit(self):
        start = self.accounts.start(dict(phone="+15555550123", name="Owner"))
        for _ in range(5):
            with self.assertRaises(UserError): self.accounts.check(dict(challenge=start["challenge"], code="000000"))
        with self.assertRaises(UserError): self.accounts.check(dict(challenge=start["challenge"], code="654321"))
        self.now += 601
        with self.assertRaises(UserError): self.accounts.check(dict(challenge=start["challenge"], code="654321"))

    def test_resend_cooldown_and_daily_limit(self):
        self.accounts.start(dict(phone="+15555550123", name="Owner"))
        with self.assertRaises(UserError): self.accounts.start(dict(phone="+15555550123", name="Owner"))
        for _ in range(4):
            self.now += 61
            self.accounts.start(dict(phone="+15555550123", name="Owner"))
        self.now += 61
        with self.assertRaises(UserError): self.accounts.start(dict(phone="+15555550123", name="Owner"))
        self.assertEqual(self.provider.send.call_count, 5)

    def test_provider_failure_never_creates_account(self):
        self.provider.send.side_effect = UserError("Unavailable", 503)
        with self.assertRaises(UserError): self.accounts.start(dict(phone="+15555550123", name="Owner"))
        self.assertFalse(self.store.data["users"])

    def test_existing_name_is_not_overwritten_by_login_attempt(self):
        first = self.login()
        self.now += 61
        second = self.login(name="Different input")
        self.assertEqual(second["user"], first["user"])
        self.accounts.action(second["token"], "/users/profile", dict(name="Updated Name"))
        self.assertEqual(self.accounts.me(first["token"])["user"]["name"], "Updated Name")

    def test_sessions_expire_and_logout_revokes(self):
        owner = self.login()
        self.accounts.action(owner["token"], "/users/logout", {})
        with self.assertRaises(UserError): self.accounts.me(owner["token"])
        self.now += 61
        owner = self.login()
        self.now += 30 * 86400 + 1
        with self.assertRaises(UserError): self.accounts.me(owner["token"])

    def test_create_join_roles_privacy_and_isolation(self):
        owner = self.login()
        c = self.create(owner["token"])
        self.assertEqual(c["role"], "leader")
        friend = self.login("+15555550124", "Demo Friend")
        self.assertEqual(friend["circles"], [])
        joined = self.accounts.action(friend["token"], "/users/circles/join", dict(invite_code=c["invite_code"].lower(), role="friend"))
        self.assertEqual(joined["circles"][0]["role"], "friend")
        self.assertNotIn("invite_code", joined["circles"][0])
        self.assertNotIn(owner["user"]["phone"], json.dumps(joined))
        self.assertEqual(len(joined["circles"][0]["members"]), 2)
        outsider = self.login("+15555550125", "Other")
        self.assertEqual(outsider["circles"], [])

    def test_join_cannot_promote_or_demote_leader_and_does_not_duplicate(self):
        owner = self.login()
        c = self.create(owner["token"])
        with self.assertRaises(UserError): self.accounts.action(owner["token"], "/users/circles/join", dict(invite_code=c["invite_code"], role="leader"))
        result = self.accounts.action(owner["token"], "/users/circles/join", dict(invite_code=c["invite_code"], role="friend"))
        self.assertEqual(result["circles"][0]["role"], "leader")
        self.assertEqual(len(result["circles"][0]["members"]), 1)

    def test_rotation_requires_leader_and_invalidates_old_code(self):
        owner = self.login(); c = self.create(owner["token"])
        friend = self.login("+15555550124", "Friend")
        self.accounts.action(friend["token"], "/users/circles/join", dict(invite_code=c["invite_code"], role="family"))
        with self.assertRaises(UserError): self.accounts.action(friend["token"], "/users/circles/rotate", dict(circle_id=c["id"]))
        updated = self.accounts.action(owner["token"], "/users/circles/rotate", dict(circle_id=c["id"]))
        self.assertNotEqual(updated["circles"][0]["invite_code"], c["invite_code"])
        self.assertEqual(len(updated["circles"][0]["members"]), 2)
        with self.assertRaises(UserError): self.accounts.action(friend["token"], "/users/circles/join", dict(invite_code=c["invite_code"], role="family"))

    def test_leave_revokes_circle_access_and_leader_cannot_leave(self):
        owner = self.login(); c = self.create(owner["token"])
        friend = self.login("+15555550124", "Friend")
        self.accounts.action(friend["token"], "/users/circles/join", dict(invite_code=c["invite_code"], role="family"))
        self.assertFalse(self.accounts.action(friend["token"], "/users/circles/leave", dict(circle_id=c["id"]))["circles"])
        with self.assertRaises(UserError): self.accounts.action(friend["token"], "/users/circles/leave", dict(circle_id=c["id"]))
        with self.assertRaises(UserError): self.accounts.action(owner["token"], "/users/circles/leave", dict(circle_id=c["id"]))

    def test_concurrent_joins_keep_both_members(self):
        owner = self.login(); c = self.create(owner["token"])
        a = self.login("+15555550124", "A"); b = self.login("+15555550125", "B")
        with ThreadPoolExecutor(2) as executor:
            results = list(executor.map(lambda token: self.accounts.action(token, "/users/circles/join", dict(invite_code=c["invite_code"], role="family")), [a["token"], b["token"]]))
        self.assertEqual(len(self.accounts.me(owner["token"])["circles"][0]["members"]), 3)

    def test_invalid_names_phones_and_empty_token_rejected(self):
        for payload in [dict(name="", phone="+15555550123"), dict(name="Bad\nName", phone="+15555550123"), dict(name="Owner", phone="123")]:
            with self.assertRaises(UserError): self.accounts.start(payload)
        with self.assertRaises(UserError): self.accounts.me("")


class AccountHTTPTests(unittest.TestCase):
    def setUp(self):
        verifier = Mock(); verifier.send.return_value = "VE-test"; verifier.check.return_value = True
        self.accounts = Accounts(MemoryDirectory(), verifier)
        self.http = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Mock(), "owner-demo-token", accounts=self.accounts))
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True); self.thread.start()

    def tearDown(self):
        self.http.shutdown(); self.http.server_close(); self.thread.join()

    def request(self, path, payload=None, token=""):
        headers = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
        req = urllib.request.Request("http://127.0.0.1:" + str(self.http.server_port) + path,
            data=json.dumps(payload).encode() if payload is not None else None, headers=headers)
        try:
            with urllib.request.urlopen(req) as result: return result.status, json.loads(result.read())
        except urllib.error.HTTPError as error: return error.code, json.loads(error.read())

    def test_public_sign_in_private_profile_and_no_legacy_demo_access(self):
        self.assertEqual(self.request("/users/me")[0], 401)
        self.assertEqual(self.request("/users/me", token="owner-demo-token")[0], 401)
        status, start = self.request("/users/auth/start", dict(name="Synthetic", phone="+15555550123"))
        self.assertEqual(status, 200)
        status, signed = self.request("/users/auth/check", dict(challenge=start["challenge"], code="654321"))
        self.assertEqual(status, 200)
        self.assertEqual(self.request("/users/me", token=signed["token"])[0], 200)
        self.assertEqual(self.request("/appointments", token=signed["token"])[0], 401)
        self.assertEqual(self.request("/sms/consent", token=signed["token"])[0], 401)
        self.assertEqual(self.request("/users/logout", {}, signed["token"])[0], 200)
        self.assertEqual(self.request("/users/me", token=signed["token"])[0], 401)
