"""Presentation-only, durable delayed ride requests for authenticated care circles.

No transcripts enter prompts or SMS. Delivery requires fresh membership/consent,
carrier approval and a claimed daily slot. Ambiguous sends are never retried.
"""
import copy
import hashlib
import json
import re
import threading
import time
import uuid
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from users import UserError
from visits import ident
from coordinator import SendRejected, REPLY


class CircleTransport:
    def __init__(self, coordinator, accounts, visits, planner=None, clock=time.time):
        self.coordinator, self.accounts, self.visits = coordinator, accounts, visits
        self.store, self.sender, self.planner, self.clock = coordinator.store, coordinator.sender, planner, clock
        self.wake = threading.Event()
        self.lock = threading.Lock()

    @staticmethod
    def data(state):
        return state.setdefault("circle_transport", {"events": {}, "jobs": {}, "rides": {}, "inbound": {}})

    def schedule(self, token, payload):
        circle = payload.get("circle_id"); uid, _ = self.accounts.circle_identity(token, circle)
        vid = ident(payload.get("visit_id")); c = self.accounts.transport_circle(circle)
        if not c["enabled"]: return {"scheduled": False, "reason": "Presentation transport is off."}
        key = circle + "/" + vid; now = self.clock()
        def save(state):
            data = self.data(state)
            if key not in data["events"]:
                # A retry of the same recording cannot reset its timer or duplicate requests.
                if len(data["events"]) >= 200: raise UserError("Presentation history is full. Contact the developer.", 503)
                data["events"][key] = {"circle_id": circle, "visit_id": vid, "creator_id": uid,
                    "due_at": now + 20, "expires_at": now + 620, "state": "scheduled", "detail": "Checking appointments 20 seconds after recording ends."}
            event = data["events"][key]
            if event["creator_id"] != uid: raise UserError("This recording belongs to another circle member.", 403)
            return {"scheduled": True, "due_at": event["due_at"]}
        result = self.store.update(save); self.wake.set(); return result

    @staticmethod
    def appointment_key(circle, record):
        a = record["appointment"]
        revision = json.dumps({k: a[k] for k in ("id", "start", "end", "time_zone", "status")}, sort_keys=True)
        return circle + "/" + hashlib.sha256(revision.encode()).hexdigest()[:24]

    def message(self, patient, appointment):
        at = datetime.fromisoformat(appointment["start"]).astimezone(ZoneInfo(appointment["time_zone"]))
        when = at.strftime("%B %-d, %Y at %-I:%M %p %Z")
        fallback = f"Hi, this is {patient}'s Encircle. Can you take {patient} to the hospital on {when}?"
        body, source = fallback, "template"
        if self.planner:
            try:
                text = self.planner.chat([{"role": "user", "content":
                    "Write one gentle, short SMS asking a family member for a hospital ride. Return only the message, no markdown. "
                    "Start with Hi, this is the patient's Encircle. Do not claim a ride is arranged or add medical details. "
                    "Include the exact patient name and exact date/time below; do not add any other dates, times, phone numbers or URLs. Facts: " +
                    json.dumps({"patient": patient, "date_time": when})}]).strip()
                # Trusted facts and the reply instructions remain under application control.
                numbers = re.findall(r"\d+", text)
                if patient in text and when in text and 20 <= len(text) <= 250 and not re.search(r"[*_<>\[\]#]|https?://", text) and all(n in re.findall(r"\d+", when) for n in numbers):
                    body, source = text.replace("!", "."), "Oracle AI"
            except Exception: pass
        if appointment.get("is_test_data"): body = "DEMO · " + body
        return body, source

    def update_event(self, key, **fields):
        self.store.update(lambda state: self.data(state)["events"][key].update(fields))

    def prepare(self):
        now = self.clock(); state = self.store.read()
        for key, event in list(self.data(state)["events"].items()):
            if event["state"] not in ("scheduled", "waiting_for_recording") or event["due_at"] > now: continue
            if event["expires_at"] <= now:
                self.update_event(key, state="expired", detail="Recording did not reach the cloud before this presentation request expired."); continue
            c = self.accounts.transport_circle(event["circle_id"])
            if not c or not c["enabled"] or event["creator_id"] not in [p["id"] for p in c["people"]]:
                self.update_event(key, state="cancelled", detail="Presentation transport was turned off or the recorder left the circle."); continue
            try: record, _ = self.visits.record(event["circle_id"], event["visit_id"])
            except UserError as error:
                if error.status == 404:
                    self.update_event(key, state="waiting_for_recording", detail="Waiting for the completed recording to upload."); continue
                raise
            if record["creator_id"] != event["creator_id"] or not record["visit"]["complete"]:
                self.update_event(key, state="cancelled", detail="Interrupted or mismatched recording; no texts requested."); continue
            appointments = [r for r in self.store.read()["appointments"].values() if r["appointment"]["status"] == "booked"
                and datetime.fromisoformat(r["appointment"]["start"]).timestamp() > now]
            drafts = []
            for appointment in sorted(appointments, key=lambda r: r["appointment"]["start"]):
                ride = self.appointment_key(event["circle_id"], appointment)
                existing = self.data(self.store.read())
                if existing["rides"].get(ride): continue
                body, source = self.message(c["patient_name"], appointment["appointment"])
                for p in c["people"]:
                    job_id = "circle-" + hashlib.sha256((ride + "/" + p["id"]).encode()).hexdigest()[:32]
                    code = hashlib.sha256(job_id.encode()).hexdigest()[:10].upper()
                    drafts.append({"id": job_id, "event": key, "circle_id": event["circle_id"], "creator_id": event["creator_id"],
                        "member_id": p["id"], "name": p["name"], "to": p["phone"], "ride": ride,
                        "appointment_id": appointment["appointment"]["id"], "code": code, "kind": "request",
                        "body": body + f" Reply YES {code} or NO {code}. STOP to opt out.", "source": source,
                        "state": "pending", "created_at": now, "expires_at": event["expires_at"], "sid": None})
            def commit(current):
                data = self.data(current)
                if len(data["jobs"]) + len(drafts) > 1000: raise UserError("Presentation message history is full.", 503)
                for job in drafts:
                    old = data["jobs"].get(job["id"])
                    if old is None or (old["state"] in ("expired", "cancelled", "failed") and not old.get("sid")):
                        data["jobs"][job["id"]] = job
                data["events"][key].update(state="checked", detail="Appointments checked; requests require member consent and an approved SMS sender." if drafts else "No new uncovered appointments need requests.")
            self.store.update(commit)

    def dispatch(self):
        for job_id, original in list(self.data(self.store.read())["jobs"].items()):
            now = self.clock()
            if original["state"] not in ("pending", "sending"): continue
            if original["state"] == "sending":
                if now - original["claimed_at"] > 120:
                    self.store.update(lambda s: self.data(s)["jobs"][job_id].update(state="uncertain", detail="Delivery acceptance is uncertain; not retried."))
                continue
            c = self.accounts.transport_circle(original["circle_id"])
            people = {p["id"]: p for p in c["people"]} if c else {}
            p = people.get(original["member_id"])
            record = self.store.read()["appointments"].get(original["appointment_id"])
            cancelled = not c or not c["enabled"] or original["creator_id"] not in people or not p or not record
            if not cancelled:
                cancelled = self.appointment_key(original["circle_id"], record) != original["ride"] or datetime.fromisoformat(record["appointment"]["start"]).timestamp() <= now
            reason = None
            if not cancelled and not p["consent"]: reason = "This member needs to save SMS consent in their account."
            if not cancelled and (not self.sender.ready or not self.sender.approval_status()): reason = "Twilio sender approval is required."
            day = datetime.fromtimestamp(now, timezone.utc).date().isoformat()
            def claim(state):
                data = self.data(state); job = data["jobs"][job_id]
                if job["state"] != "pending": return None
                if cancelled or (job["kind"] == "request" and data["rides"].get(job["ride"])):
                    job.update(state="cancelled", detail="Circle membership, appointment or ride coverage changed."); return None
                if now >= job["expires_at"]:
                    job.update(state="expired", detail="Presentation window expired; finish a new recording after setup is ready."); return None
                if reason: job["detail"] = reason; return None
                used = sum(j.get("live_day") == day for j in data["jobs"].values()) + sum(j.get("live_day") == day for j in state["jobs"].values())
                if used >= 20: job["detail"] = "Daily limit of 20 outgoing messages reached."; return None
                job.update(state="sending", claimed_at=now, live_day=day, to=p["phone"])
                job.pop("detail", None)
                return copy.deepcopy(job)
            job = self.store.update(claim)
            if not job: continue
            try: sid = self.sender.send_circle(job); outcome = "accepted"; detail = "Accepted by Twilio; delivery is not yet confirmed."
            except SendRejected: sid = None; outcome = "failed"; detail = "Twilio rejected the message. Check sender approval and verified trial recipients."
            except Exception: sid = None; outcome = "uncertain"; detail = "Delivery acceptance is uncertain; not retried."
            def finish(state):
                current = self.data(state)["jobs"][job_id]
                if current["state"] == "sending": current.update(state=outcome, detail=detail)
                if sid: current["sid"] = sid
            self.store.update(finish)

    def status(self, token, circle):
        self.accounts.circle_identity(token, circle)
        c = self.accounts.transport_circle(circle); data = self.data(self.store.read())
        return {"enabled": c["enabled"], "sms_approved": self.sender.approval_status(),
            "members": [{"name": p["name"], "consent": p["consent"]} for p in c["people"]],
            "events": [{k: e[k] for k in ("visit_id", "due_at", "state", "detail")} for e in list(data["events"].values()) if e["circle_id"] == circle][-10:],
            "messages": [{k: j.get(k) for k in ("id", "name", "body", "state", "detail", "response", "source")} for j in data["jobs"].values() if j["circle_id"] == circle][-60:]}

    def callback(self, job_id, params):
        def update(state):
            job = self.data(state)["jobs"].get(job_id)
            status = params.get("MessageStatus"); sid = params.get("MessageSid")
            if not job or not sid or params.get("To") != job["to"] or (job.get("sid") and job["sid"] != sid): return
            ranks = {"pending": 0, "sending": 1, "accepted": 1, "uncertain": 1, "queued": 1, "sent": 2, "delivered": 3, "undelivered": 3, "failed": 3}
            if status not in ranks or ranks[status] < ranks.get(job["state"], 99): return
            job.update(state=status, sid=sid, detail="Delivery confirmed." if status == "delivered" else "Twilio status: " + status)
        self.store.update(update)

    def inbound(self, phone, body, sid, opt_out_type=None):
        command = (opt_out_type or body).strip().upper()
        if command in ("STOP", "UNSUBSCRIBE", "CANCEL", "END", "QUIT", "STOPALL", "REVOKE", "OPTOUT"):
            self.accounts.sms_stop(phone); self.wake.set(); return
        if command in ("START", "UNSTOP"):
            self.accounts.sms_stop(phone, stopped=False); return
        match = REPLY.fullmatch(command)
        if not match or not sid or len(sid) > 100: return
        intent, code = match.groups()
        def reply(state):
            data = self.data(state)
            if sid in data["inbound"]: return
            job = next((j for j in data["jobs"].values() if j["code"] == code.upper() and j["to"] == phone and j["kind"] == "request"), None)
            if not job or job["state"] not in ("accepted", "queued", "sent", "delivered", "uncertain") or job["expires_at"] <= self.clock(): return
            c = self.accounts.transport_circle(job["circle_id"])
            p = next((p for p in c["people"] if p["id"] == job["member_id"] and p["consent"] and p["phone"] == phone), None) if c and c["enabled"] else None
            a = state["appointments"].get(job["appointment_id"])
            if not p or not a or self.appointment_key(job["circle_id"], a) != job["ride"]: return
            data["inbound"][sid] = self.clock()
            if len(data["inbound"]) > 2000: data["inbound"] = dict(list(data["inbound"].items())[-2000:])
            if job.get("response"): return
            if intent == "NO": job["response"] = "declined"; return
            if intent != "YES" or job["ride"] in data["rides"]: return
            job["response"] = "confirmed"
            data["rides"][job["ride"]] = {"member_id": p["id"], "name": p["name"], "at": self.clock()}
            for leader in [p for p in c["people"] if p["role"] == "leader"]:
                key = "circle-" + hashlib.sha256((job["ride"] + "/leader-confirmation").encode()).hexdigest()[:32]
                data["jobs"].setdefault(key, {**copy.deepcopy(job), "id": key, "to": leader["phone"], "name": leader["name"],
                    "member_id": leader["id"], "kind": "leader", "state": "pending", "sid": None, "response": None,
                    "live_day": None, "expires_at": self.clock() + 600,
                    "body": f"Encircle DEMO: {p['name']} confirmed the ride for {c['patient_name']}. Appointment: {a['appointment']['start']}. Reply STOP to opt out."})
        self.store.update(reply); self.wake.set()

    def tick(self):
        if not self.lock.acquire(blocking=False): return
        try: self.prepare(); self.dispatch()
        finally: self.lock.release()

    def start(self):
        def run():
            while True:
                self.wake.clear()
                try: self.tick()
                except Exception: print("Circle transport check failed; private queue retained.", flush=True)
                self.wake.wait(1)
        threading.Thread(target=run, name="circle-transport", daemon=True).start()
