import copy
import json
import time
import unittest
import uuid
from pathlib import Path
from unittest.mock import Mock
from coordinator import Coordinator, MemoryState, SendRejected
from circle_transport import CircleTransport
from users import Accounts, MemoryDirectory, UserError
from visits import CloudVisits, MemoryObjects
import sms_consent


class Sender:
    ready = True
    def __init__(self): self.approved = True; self.sent = []; self.error = None
    def approval_status(self): return self.approved
    def send_circle(self, job):
        self.sent.append(copy.deepcopy(job))
        if self.error: raise self.error
        return "SM" + str(len(self.sent)).zfill(32)


class CircleTransportTests(unittest.TestCase):
    def setUp(self):
        self.now = 1792328400.0  # October 2026, before the synthetic appointment dates.
        verifier = Mock(); verifier.send.return_value = "VE-test"; verifier.check.return_value = True
        self.accounts = Accounts(MemoryDirectory(), verifier, clock=lambda: self.now)
        def login(phone, name):
            start = self.accounts.start({"phone": phone, "name": name})
            return self.accounts.check({"challenge": start["challenge"], "code": "123456"})
        self.leader = login("+15555550123", "Leader")
        self.friend = login("+15555550124", "Friend")
        self.outsider = login("+15555550125", "Outsider")
        self.circle = self.accounts.action(self.leader["token"], "/users/circles/create", {"name": "Synthetic circle", "patient_name": "Jessie"})["circles"][0]
        self.cid = self.circle["id"]
        self.accounts.action(self.friend["token"], "/users/circles/join", {"invite_code": self.circle["invite_code"], "role": "friend"})
        self.enable(True)
        for user in (self.leader, self.friend):
            self.accounts.consent(user["token"], {"action": "accept", "name": user["user"]["name"], "phone": user["user"]["phone"], "accepted": True, "version": sms_consent.VERSION})
        self.sender = Sender(); self.store = MemoryState()
        self.coordinator = Coordinator(self.store, self.sender, clock=lambda: self.now)
        self.coordinator.seed(json.loads((Path(__file__).parent / "fixtures/appointments.json").read_text()))
        self.visits = CloudVisits(self.accounts, MemoryObjects())
        self.transport = CircleTransport(self.coordinator, self.accounts, self.visits, clock=lambda: self.now)
        self.vid = str(uuid.uuid4()).upper()
        self.visits.save(self.leader["token"], {"circle_id": self.cid, "visit": {"id": self.vid, "date": self.now - 978307200,
            "duration": 30, "complete": True, "lines": [], "partial": ""}})

    def enable(self, value):
        return self.accounts.action(self.leader["token"], "/users/circles/presentation", {"circle_id": self.cid, "enabled": str(value).lower()})
    def schedule(self): return self.transport.schedule(self.leader["token"], {"circle_id": self.cid, "visit_id": self.vid})
    def due(self): self.schedule(); self.now += 20; self.transport.tick()
    def jobs(self): return self.store.read()["circle_transport"]["jobs"]

    def test_twenty_second_delay_and_three_real_fixture_times(self):
        self.schedule(); self.now += 19.99; self.transport.tick(); self.assertEqual(self.sender.sent, [])
        self.now += .01; self.transport.tick(); self.assertEqual(len(self.sender.sent), 6)
        bodies = [j["body"] for j in self.sender.sent]
        self.assertTrue(any("November 3, 2026 at 5:00 PM CST" in b for b in bodies))
        self.assertTrue(any("November 13, 2026 at 2:00 PM CST" in b for b in bodies))
        self.assertTrue(any("December 2, 2026 at 8:00 AM CST" in b for b in bodies))
        self.assertTrue(all("Jessie" in b and "STOP" in b and "DEMO" in b for b in bodies))

    def test_retry_and_restart_do_not_reset_timer_or_duplicate_messages(self):
        due = self.schedule()["due_at"]; self.now += 10
        self.assertEqual(self.schedule()["due_at"], due)
        self.transport = CircleTransport(self.coordinator, self.accounts, self.visits, clock=lambda: self.now)
        self.now += 10; self.transport.tick(); self.transport.tick(); self.schedule(); self.transport.tick()
        self.assertEqual(len(self.sender.sent), 6)

    def test_expired_session_and_other_circle_cannot_schedule_or_read(self):
        for token in ("", self.outsider["token"]):
            with self.assertRaises(UserError): self.transport.schedule(token, {"circle_id": self.cid, "visit_id": self.vid})
            with self.assertRaises(UserError): self.transport.status(token, self.cid)
        with self.assertRaises(UserError): self.accounts.action(self.friend["token"], "/users/circles/presentation", {"circle_id": self.cid, "enabled": "true"})

    def test_disable_and_membership_removal_cancel_pending_messages(self):
        self.schedule(); self.enable(False); self.now += 20; self.transport.tick()
        self.assertEqual(self.sender.sent, [])
        self.enable(True); self.vid = str(uuid.uuid4()).upper(); self.schedule()
        self.accounts.action(self.friend["token"], "/users/circles/leave", {"circle_id": self.cid})
        self.assertEqual(len(self.accounts.transport_circle(self.cid)["people"]), 1)

    def test_missing_or_interrupted_recording_does_not_send(self):
        self.vid = str(uuid.uuid4()).upper(); self.due(); self.assertEqual(self.sender.sent, [])
        self.visits.save(self.leader["token"], {"circle_id": self.cid, "visit": {"id": self.vid, "date": self.now - 978307200,
            "duration": 30, "complete": False, "lines": [], "partial": ""}})
        self.transport.tick(); self.assertEqual(self.sender.sent, [])

    def test_consent_withdrawal_and_provider_approval_block_delivery(self):
        self.accounts.consent(self.friend["token"], {"action": "withdraw", "phone": self.friend["user"]["phone"]})
        self.due(); self.assertEqual(len(self.sender.sent), 3)
        self.assertTrue(all(j["member_id"] == self.leader["user"]["id"] for j in self.sender.sent))
        self.sender.approved = False; self.transport.tick(); self.assertEqual(len(self.sender.sent), 3)
        self.now += 601; self.transport.tick()
        self.assertTrue(all(j["state"] != "pending" for j in self.jobs().values()))

    def test_failed_or_uncertain_acceptance_is_not_blindly_retried(self):
        self.sender.error = RuntimeError("network timeout")
        self.due(); self.assertEqual(len(self.sender.sent), 6)
        self.transport.tick(); self.assertEqual(len(self.sender.sent), 6)
        self.assertTrue(all(j["state"] == "uncertain" for j in self.jobs().values()))

    def test_stop_revokes_account_consent_and_stops_queued_requests(self):
        self.sender.approved = False; self.due()
        self.transport.inbound(self.friend["user"]["phone"], "STOP", "SM-stop")
        self.sender.approved = True; self.transport.tick()
        self.assertEqual(len(self.sender.sent), 3)
        self.assertFalse(self.accounts.consent(self.friend["token"])["active"])

    def test_reply_assigns_one_driver_and_notifies_leader_once(self):
        self.due(); job = next(j for j in self.sender.sent if j["member_id"] == self.friend["user"]["id"])
        self.transport.inbound(job["to"], "YES " + job["code"], "SM-reply")
        self.transport.inbound(job["to"], "YES " + job["code"], "SM-reply")
        self.transport.tick()
        self.assertEqual(len([j for j in self.sender.sent if j["kind"] == "leader"]), 1)
        other = next(j for j in self.sender.sent if j["ride"] == job["ride"] and j["kind"] == "request" and j["member_id"] != job["member_id"])
        self.transport.inbound(other["to"], "YES " + other["code"], "SM-second-reply")
        self.transport.tick()
        self.assertEqual(len([j for j in self.sender.sent if j["kind"] == "leader"]), 1)
        self.assertEqual(self.store.read()["circle_transport"]["rides"][job["ride"]]["member_id"], self.friend["user"]["id"])

    def test_twilio_acceptance_is_separate_from_delivery_confirmation(self):
        self.due(); job = self.sender.sent[0]
        self.transport.callback(job["id"], {"To": job["to"], "MessageSid": self.jobs()[job["id"]]["sid"], "MessageStatus": "delivered"})
        self.assertEqual(self.jobs()[job["id"]]["state"], "delivered")
        self.transport.callback(job["id"], {"To": job["to"], "MessageSid": "wrong-sid", "MessageStatus": "failed"})
        self.assertEqual(self.jobs()[job["id"]]["state"], "delivered")

    def test_shared_daily_budget_and_no_transcript_in_ai_prompt(self):
        self.store.update(lambda s: s["jobs"].update({str(i): {"live_day": "2026-10-18"} for i in range(19)}))
        self.transport.planner = Mock(); self.transport.planner.chat.return_value = "Bad facts: November 3 at 3pm"
        self.due(); self.assertEqual(len(self.sender.sent), 1)
        self.assertIn("5:00 PM", self.sender.sent[0]["body"])
        self.assertNotIn("transcript", str(self.transport.planner.chat.call_args).lower())
