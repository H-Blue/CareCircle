import copy
import hashlib
import json
import time
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import Mock

from users import Accounts, MemoryDirectory, UserError
from visits import CHUNK, CloudVisits, MemoryObjects, visit_data


class CloudVisitTests(unittest.TestCase):
    def setUp(self):
        verifier = Mock(); verifier.send.return_value = "VE-test"; verifier.check.return_value = True
        self.accounts = Accounts(MemoryDirectory(), verifier)
        self.leader = self.login("+15555550123", "Synthetic leader")
        self.friend = self.login("+15555550124", "Synthetic friend")
        self.outsider = self.login("+15555550125", "Other circle")
        self.circle = self.accounts.action(self.leader["token"], "/users/circles/create", {"name": "Synthetic circle", "patient_name": "Synthetic patient"})["circles"][0]
        self.accounts.action(self.friend["token"], "/users/circles/join", {"invite_code": self.circle["invite_code"], "role": "friend"})
        self.store = MemoryObjects()
        self.chat = Mock(); self.chat.chat.return_value = "Your scan showed no broken bone. Arrange a check-in in two weeks."
        self.visits = CloudVisits(self.accounts, self.store, self.chat)
        self.data = {"id": str(uuid.uuid4()).upper(), "date": time.time() - 978307200, "duration": 30, "complete": True,
            "partial": "", "lines": [{"id": str(uuid.uuid4()).upper(), "text": "Clinician: No fracture was seen. Please arrange follow-up in two weeks.", "elapsed": 0}]}
        self.payload = {"circle_id": self.circle["id"], "visit": self.data}

    def login(self, phone, name):
        start = self.accounts.start({"phone": phone, "name": name})
        return self.accounts.check({"challenge": start["challenge"], "code": "123456"})

    def wait(self, predicate):
        for _ in range(100):
            if predicate(): return
            time.sleep(.01)
        self.fail("Background storage task did not finish")

    def test_circle_members_share_transcript_and_outsider_is_denied(self):
        saved = self.visits.save(self.leader["token"], self.payload)
        friend = self.visits.listing(self.friend["token"], self.circle["id"])["visits"]
        self.assertEqual(friend[0]["visit"]["lines"], self.data["lines"])
        self.assertEqual(friend[0]["creator_id"], self.leader["user"]["id"])
        with self.assertRaises(UserError): self.visits.listing(self.outsider["token"], self.circle["id"])
        with self.assertRaises(UserError): self.visits.listing("", self.circle["id"])
        with self.assertRaises(UserError): self.visits.listing("legacy-owner-token", self.circle["id"])

    def test_save_is_idempotent_but_other_member_cannot_overwrite(self):
        a = self.visits.save(self.leader["token"], self.payload)
        b = self.visits.save(self.leader["token"], self.payload)
        self.assertEqual(a["revision"], b["revision"])
        with self.assertRaises(UserError): self.visits.save(self.friend["token"], self.payload)
        changed = copy.deepcopy(self.payload); changed["visit"]["partial"] = "More captured words"
        with self.assertRaises(UserError): self.visits.save(self.leader["token"], changed)
        changed["revision"] = a["revision"]
        updated = self.visits.save(self.leader["token"], changed)
        self.assertNotEqual(updated["revision"], a["revision"])

    def test_archiving_is_personal_and_survives_service_restart(self):
        self.visits.save(self.leader["token"], self.payload)
        p = {"circle_id": self.circle["id"], "visit_id": self.data["id"], "archived": True}
        self.visits.archive(self.friend["token"], p)
        reloaded = CloudVisits(self.accounts, self.store)
        self.assertTrue(reloaded.listing(self.friend["token"], self.circle["id"])["visits"][0]["visit"]["archived"])
        self.assertFalse(reloaded.listing(self.leader["token"], self.circle["id"])["visits"][0]["visit"]["archived"])
        self.visits.archive(self.friend["token"], {**p, "archived": False})
        self.assertFalse(self.visits.listing(self.friend["token"], self.circle["id"])["visits"][0]["visit"]["archived"])

    def test_audio_resume_checksum_download_and_membership_revocation(self):
        self.visits.save(self.leader["token"], self.payload)
        audio = b"synthetic-audio-" * (CHUNK // 10)
        sha = hashlib.sha256(audio).hexdigest()
        p = {"circle_id": self.circle["id"], "visit_id": self.data["id"], "sha": sha, "bytes": len(audio)}
        start = self.visits.audio_start(self.leader["token"], p)
        self.assertEqual(start["uploaded"], [])
        self.visits.audio_part(self.leader["token"], self.circle["id"], self.data["id"], sha, 0, audio[:CHUNK])
        resumed = CloudVisits(self.accounts, self.store, self.chat)
        self.assertEqual(resumed.audio_start(self.leader["token"], p)["uploaded"], [0])
        self.assertFalse(resumed.listing(self.friend["token"], self.circle["id"])["visits"][0]["audio_ready"])
        with self.assertRaises(UserError): resumed.audio_part(self.friend["token"], self.circle["id"], self.data["id"], sha, 0, audio[:CHUNK])
        for index in range(1, (len(audio) + CHUNK - 1) // CHUNK):
            resumed.audio_part(self.leader["token"], self.circle["id"], self.data["id"], sha, index, audio[index * CHUNK:(index + 1) * CHUNK])
        resumed.audio_finish(self.leader["token"], p)
        self.wait(lambda: resumed.record(self.circle["id"], self.data["id"])[0].get("audio") is not None)
        record = resumed.listing(self.friend["token"], self.circle["id"])["visits"][0]
        downloaded = b"".join(resumed.audio_part(self.friend["token"], self.circle["id"], self.data["id"], None, index) for index in range(record["audio_parts"]))
        self.assertEqual(downloaded, audio)
        self.accounts.action(self.friend["token"], "/users/circles/leave", {"circle_id": self.circle["id"]})
        with self.assertRaises(UserError): resumed.audio_part(self.friend["token"], self.circle["id"], self.data["id"], None, 0)
        with self.assertRaises(UserError): resumed.listing(self.friend["token"], self.circle["id"])

    def test_audio_integrity_failure_never_publishes_recording(self):
        self.visits.save(self.leader["token"], self.payload)
        p = {"circle_id": self.circle["id"], "visit_id": self.data["id"], "sha": hashlib.sha256(b"good").hexdigest(), "bytes": 4}
        self.visits.audio_start(self.leader["token"], p)
        self.visits.audio_part(self.leader["token"], self.circle["id"], self.data["id"], p["sha"], 0, b"bad!")
        self.visits.audio_finish(self.leader["token"], p)
        self.wait(lambda: self.visits.record(self.circle["id"], self.data["id"])[0].get("audio_error"))
        self.assertFalse(self.visits.listing(self.friend["token"], self.circle["id"])["visits"][0]["audio_ready"])
        # A retry gets fresh immutable part keys, so a bad attempt cannot poison later uploads.
        self.assertEqual(self.visits.audio_start(self.leader["token"], p)["uploaded"], [])
        self.visits.audio_part(self.leader["token"], self.circle["id"], self.data["id"], p["sha"], 0, b"good")
        self.visits.audio_finish(self.leader["token"], p)
        self.wait(lambda: self.visits.record(self.circle["id"], self.data["id"])[0].get("audio") is not None)
        self.assertEqual(self.visits.audio_part(self.friend["token"], self.circle["id"], self.data["id"], None, 0), b"good")

    def test_summary_is_shared_and_cannot_overwrite_newer_transcript(self):
        first = self.visits.save(self.leader["token"], self.payload)
        self.visits.summarize(self.friend["token"], {"circle_id": self.circle["id"], "visit_id": self.data["id"]})
        self.wait(lambda: bool(self.visits.record(self.circle["id"], self.data["id"])[0]["visit"].get("summary")))
        self.assertEqual(self.visits.listing(self.friend["token"], self.circle["id"])["visits"][0]["visit"]["summary"], self.chat.chat.return_value)
        # Retrying a metadata upload whose response was lost must preserve a generated summary.
        self.assertEqual(self.visits.save(self.leader["token"], self.payload)["visit"]["summary"], self.chat.chat.return_value)
        record, version = self.visits.record(self.circle["id"], self.data["id"])
        record["visit"]["partial"] = "Changed transcript"
        self.visits.write(self.visits.key(self.circle["id"], self.data["id"]), record, version)
        original = "\n".join([x["text"] for x in self.data["lines"]] + [""]).strip()
        self.visits._summary_result(self.visits.key(self.circle["id"], self.data["id"]), original, "Wrong stale summary", None)
        current, _ = self.visits.record(self.circle["id"], self.data["id"])
        self.assertNotEqual(current["visit"]["summary"], "Wrong stale summary")

    def test_delete_requires_creator_or_leader_and_hides_from_everyone(self):
        self.visits.save(self.leader["token"], self.payload)
        p = {"circle_id": self.circle["id"], "visit_id": self.data["id"]}
        with self.assertRaises(UserError): self.visits.delete(self.friend["token"], p)
        self.visits.delete(self.leader["token"], p)
        self.assertFalse(self.visits.listing(self.friend["token"], self.circle["id"])["visits"])
        with self.assertRaises(UserError): self.visits.record(self.circle["id"], self.data["id"])
        with self.assertRaises(UserError): self.visits.save(self.leader["token"], self.payload)

    def test_invalid_values_paths_and_cross_circle_cursor_are_rejected(self):
        for update in [{"id": "../../private"}, {"date": float("nan")}, {"complete": "yes"}, {"duration": -1}, {"lines": "invalid"}]:
            with self.assertRaises(UserError): visit_data({**self.data, **update})
        with self.assertRaises(UserError): self.visits.listing(self.friend["token"], self.circle["id"], "circles/another/records/")

    def test_concurrent_personal_archive_changes_do_not_lose_each_other(self):
        self.visits.save(self.leader["token"], self.payload)
        other = copy.deepcopy(self.payload); other["visit"]["id"] = str(uuid.uuid4())
        self.visits.save(self.leader["token"], other)
        with ThreadPoolExecutor(2) as pool:
            list(pool.map(lambda vid: self.visits.archive(self.friend["token"], {"circle_id": self.circle["id"], "visit_id": vid, "archived": True}), [self.data["id"], other["visit"]["id"]]))
        self.assertTrue(all(v["visit"]["archived"] for v in self.visits.listing(self.friend["token"], self.circle["id"])["visits"]))
