"""Phone-verified accounts and private circle membership, separate from the owner demo.

This bounded prototype keeps its small account directory in one conditional-write
Oracle NoSQL row, making membership and invite changes atomic. No codes or raw
session tokens are persisted. Legacy demo records are never returned here.
"""
import copy
import hashlib
import json
import os
import re
import secrets
import threading
import time
import uuid
from datetime import datetime, timezone
import sms_consent


class UserError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def phone_number(value):
    if not isinstance(value, str) or len(value) > 40:
        raise UserError("Enter your mobile number, including its country code.")
    value = re.sub(r"[\s().-]", "", value)
    if re.fullmatch(r"[0-9]{10}", value): value = "+1" + value
    elif re.fullmatch(r"1[0-9]{10}", value): value = "+" + value
    if not re.fullmatch(r"\+[1-9][0-9]{7,14}", value):
        raise UserError("Enter a valid mobile number, including its country code.")
    return value


def label(value, title, maximum=80):
    if not isinstance(value, str) or not 1 <= len(value.strip()) <= maximum or any(ord(c) < 32 for c in value):
        raise UserError(f"Enter {title} using 1–{maximum} characters on one line.")
    return value.strip()


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def empty_directory():
    return {"users": {}, "circles": {}, "sessions": {}, "challenges": {}, "daily": {}}


class MemoryDirectory:
    def __init__(self):
        self.data = empty_directory()
        self.lock = threading.RLock()

    def update(self, operation):
        with self.lock:
            candidate = copy.deepcopy(self.data)
            result = operation(candidate)
            self.data = candidate
            return copy.deepcopy(result)


class OracleDirectory:
    def __init__(self):
        import oci
        self.oci = oci
        self.table = os.environ["ENCIRCLE_USERS_TABLE"]
        region = os.environ.get("OCI_REGION", "us-chicago-1")
        if os.environ.get("OCI_AUTH") == "instance_principal":
            self.client = oci.nosql.NosqlClient({"region": region},
                signer=oci.auth.signers.InstancePrincipalsSecurityTokenSigner(), timeout=(10, 30))
        else:
            self.client = oci.nosql.NosqlClient(oci.config.from_file(os.path.expanduser(
                os.environ.get("OCI_CONFIG_FILE", "~/.oci/encircle/config"))), timeout=(10, 30))
        self.lock = threading.RLock()

    def update(self, operation):
        with self.lock:
            for _ in range(8):
                response = self.client.get_row(self.table, ["id:directory"], consistency="ABSOLUTE")
                row = response.data
                value = copy.deepcopy(row.value["data"]) if row.value else empty_directory()
                before = json.dumps(value, sort_keys=True)
                result = operation(value)
                after = json.dumps(value, sort_keys=True)
                if before == after: return result
                # Stay comfortably below the NoSQL row-size limit; fail without partial writes.
                if len(after.encode()) > 240000:
                    raise UserError("The prototype account directory is full. Please contact the circle leader.", 503)
                details = self.oci.nosql.models.UpdateRowDetails(value={"id": "directory", "data": value},
                    option="IF_PRESENT" if row.value else "IF_ABSENT")
                try:
                    saved = self.client.update_row(self.table, details,
                        **({"if_match": response.headers["etag"]} if row.value else {})).data
                    if saved.version: return result
                except self.oci.exceptions.ServiceError as error:
                    if error.status != 412: raise
            raise UserError("Your circle changed while saving. Please try again.", 409)


class VerifyProvider:
    def __init__(self):
        from twilio.rest import Client
        self.service = Client(os.environ["TWILIO_ACCOUNT_SID"], os.environ["TWILIO_AUTH_TOKEN"]).verify.v2.services(
            os.environ["TWILIO_VERIFY_SERVICE_SID"])
        # Preserve the authorized trial/demo destination restriction until explicitly changed.
        self.allowed = set(os.environ.get("TWILIO_ALLOWED_NUMBERS", "").split(","))
        self.self_service = os.environ.get("TWILIO_VERIFY_SELF_SERVICE") == "1"

    def validate(self, phone):
        if phone not in self.allowed and not (self.self_service and phone.startswith("+1")):
            raise UserError("Phone sign-in currently supports the configured test number only. Other people can join after Twilio account eligibility and recipient access are enabled.", 403)

    def send(self, phone):
        self.validate(phone)
        try:
            result = self.service.verifications.create(to=phone, channel="sms")
            if result.status != "pending": raise RuntimeError()
            return result.sid
        except UserError: raise
        except Exception:
            raise UserError("The verification text couldn’t be sent. Please try again later; the Twilio trial may need attention.", 503) from None

    def check(self, sid, code):
        try:
            return self.service.verification_checks.create(verification_sid=sid, code=code).status == "approved"
        except Exception:
            return False


class Accounts:
    def __init__(self, store, verifier, clock=time.time):
        self.store, self.verifier, self.clock = store, verifier, clock

    def clean(self, data):
        now = self.clock()
        for key in ("sessions", "challenges"):
            data[key] = {k: v for k, v in data[key].items() if v["expires"] > now}
        day = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")
        data["daily"] = {day: data["daily"].get(day, 0)}
        return day

    def start(self, payload):
        phone = phone_number(payload.get("phone"))
        name = label(payload.get("name"), "your name")
        self.verifier.validate(phone)
        challenge = secrets.token_urlsafe(32)
        now = self.clock()
        def reserve(data):
            day = self.clean(data)
            recent = [c for c in data["challenges"].values() if c["phone"] == phone]
            if recent and max(c["created"] for c in recent) > now - 60:
                raise UserError("Please wait a minute before requesting another code.", 429)
            if data["daily"][day] >= 5:
                raise UserError("Today’s sign-in text limit has been reached. Try again tomorrow.", 429)
            data["daily"][day] += 1
            data["challenges"][digest(challenge)] = {"phone": phone, "name": name, "created": now,
                "expires": now + 600, "attempts": 0, "sid": None}
        self.store.update(reserve)
        sid = self.verifier.send(phone)
        def ready(data):
            data["challenges"][digest(challenge)]["sid"] = sid
        self.store.update(ready)
        return {"challenge": challenge, "expires_in": 600, "message": "Check your phone for a six-digit sign-in code."}

    def check(self, payload):
        challenge, code = payload.get("challenge"), payload.get("code")
        if not isinstance(challenge, str) or not 20 <= len(challenge) <= 100 or not isinstance(code, str) or not re.fullmatch(r"[0-9]{6}", code):
            raise UserError("Enter the six-digit code from your text.")
        key = digest(challenge)
        def attempt(data):
            self.clean(data)
            c = data["challenges"].get(key)
            if not c or not c["sid"] or c["attempts"] >= 5:
                raise UserError("This code has expired. Request a new one.", 401)
            c["attempts"] += 1
            return c
        c = self.store.update(attempt)
        if not self.verifier.check(c["sid"], code):
            raise UserError("That code wasn’t accepted. Check the code or request a new one.", 401)
        token = secrets.token_urlsafe(48)
        def complete(data):
            self.clean(data)
            # Atomically consume the challenge so concurrent/replayed checks cannot log in twice.
            current = data["challenges"].pop(key, None)
            if not current: raise UserError("This code has already been used. Request a new one.", 401)
            user = next((u for u in data["users"].values() if u["phone"] == c["phone"]), None)
            if not user:
                if len(data["users"]) >= 100: raise UserError("The prototype’s user limit has been reached.", 503)
                user = {"id": uuid.uuid4().hex, "phone": c["phone"], "name": c["name"]}
                data["users"][user["id"]] = user
            # Keep at most three active device sessions per user.
            sessions = sorted(((k, s) for k, s in data["sessions"].items() if s["user_id"] == user["id"]), key=lambda pair: pair[1]["expires"])
            for k, _ in sessions[:-2]: del data["sessions"][k]
            data["sessions"][digest(token)] = {"user_id": user["id"], "expires": self.clock() + 30 * 86400}
            return {"token": token, **self.snapshot(data, user["id"])}
        return self.store.update(complete)

    def identity(self, data, token):
        if not isinstance(token, str) or len(token) > 128: raise UserError("Please sign in again.", 401)
        self.clean(data)
        session = data["sessions"].get(digest(token))
        if not session or session["user_id"] not in data["users"]: raise UserError("Please sign in again.", 401)
        return session["user_id"]

    def snapshot(self, data, uid):
        circles = []
        for c in data["circles"].values():
            if uid not in c["members"]: continue
            item = {k: c[k] for k in ("id", "name", "patient_name")}
            item["role"] = c["members"][uid]
            item["members"] = [{"id": mid, "name": data["users"][mid]["name"], "role": role} for mid, role in c["members"].items()]
            # Only the leader receives the join code; never expose other members' phone numbers.
            if item["role"] == "leader": item["invite_code"] = c["invite_code"]
            circles.append(item)
        return {"user": data["users"][uid], "circles": sorted(circles, key=lambda c: c["name"].casefold())}

    def me(self, token):
        return self.store.update(lambda data: self.snapshot(data, self.identity(data, token)))

    def consent(self, token, payload=None):
        def change(data):
            uid = self.identity(data, token)
            user = data["users"][uid]
            previous = user.get("sms_consent")
            if payload is not None:
                action = payload.get("action")
                if action not in ("accept", "withdraw"): raise UserError("Choose accept or withdraw.")
                if phone_number(payload.get("phone")) != user["phone"]:
                    raise UserError("You can save consent only for your own verified sign-in number.", 403)
                if action == "accept":
                    if payload.get("accepted") is not True or payload.get("version") != sms_consent.VERSION:
                        raise UserError("Read the current disclosure and check the agreement box.")
                    name = label(payload.get("name"), "your name")
                    if not previous or not previous["active"] or previous["version"] != sms_consent.VERSION or previous["name"] != name:
                        user["sms_consent"] = {"id": uuid.uuid4().hex, "name": name, "phone": user["phone"],
                            "version": sms_consent.VERSION, "disclosure": sms_consent.DISCLOSURE, "active": True,
                            "accepted_at": datetime.fromtimestamp(self.clock(), timezone.utc).isoformat(timespec="seconds"),
                            "source": "ios_app", "auth_context": "phone_verified_user"}
                elif previous and previous["active"]:
                    user["sms_consent"] = {**previous, "active": False,
                        "revoked_at": datetime.fromtimestamp(self.clock(), timezone.utc).isoformat(timespec="seconds")}
                # Keep a bounded private history; duplicate identical submissions add no event.
                if previous != user.get("sms_consent"):
                    history = user.setdefault("sms_consent_history", [])
                    history.append(copy.deepcopy(user["sms_consent"]))
                    user["sms_consent_history"] = history[-10:]
            receipt = user.get("sms_consent")
            return {"program": sms_consent.PROGRAM, "version": sms_consent.VERSION,
                "disclosure": sms_consent.DISCLOSURE, "checkbox_label": sms_consent.CHECKBOX,
                "privacy_url": sms_consent.PRIVACY_URL, "terms_url": sms_consent.TERMS_URL, "proof_url": sms_consent.PROOF_URL,
                "active": bool(receipt and receipt["active"] and receipt["version"] == sms_consent.VERSION),
                "opted_out_by_sms": False, "transport_connected": False,
                "verified_name": user["name"], "verified_phone": user["phone"],
                "receipt": {k: receipt[k] for k in ("id", "name", "phone", "accepted_at", "revoked_at", "version") if k in receipt} if receipt else None}
        return self.store.update(change)

    def action(self, token, path, payload):
        def change(data):
            uid = self.identity(data, token)
            if path == "/users/logout":
                data["sessions"].pop(digest(token), None)
                return {"signed_out": True}
            if path == "/users/profile":
                data["users"][uid]["name"] = label(payload.get("name"), "your name")
            elif path == "/users/circles/create":
                if sum(uid in c["members"] for c in data["circles"].values()) >= 10 or len(data["circles"]) >= 100:
                    raise UserError("The prototype’s circle limit has been reached.")
                c = {"id": uuid.uuid4().hex, "name": label(payload.get("name"), "a circle name"),
                    "patient_name": label(payload.get("patient_name"), "the name of the person receiving care"),
                    "members": {uid: "leader"}, "invite_code": secrets.token_hex(8).upper()}
                data["circles"][c["id"]] = c
            elif path == "/users/circles/join":
                code = payload.get("invite_code", "")
                role = payload.get("role")
                if not isinstance(code, str) or role not in ("family", "friend"): raise UserError("Choose family or friend and enter a circle’s invitation code.")
                code = re.sub(r"[\s-]", "", code).upper()
                if not re.fullmatch(r"[A-F0-9]{16}", code): raise UserError("Enter the 16-character invitation code from the circle leader.")
                c = next((c for c in data["circles"].values() if secrets.compare_digest(c["invite_code"], code)), None)
                if not c: raise UserError("That invitation code wasn’t found. Ask the circle leader for the current code.")
                if uid not in c["members"]:
                    if len(c["members"]) >= 20 or sum(uid in x["members"] for x in data["circles"].values()) >= 10:
                        raise UserError("The prototype’s membership limit has been reached.")
                    c["members"][uid] = role
            elif path == "/users/circles/rotate":
                c = data["circles"].get(payload.get("circle_id"))
                if not c or c["members"].get(uid) != "leader": raise UserError("Only the circle leader can replace this invitation code.", 403)
                c["invite_code"] = secrets.token_hex(8).upper()
            elif path == "/users/circles/leave":
                c = data["circles"].get(payload.get("circle_id"))
                if not c or uid not in c["members"]: raise UserError("This circle isn’t available to your account.", 403)
                if c["members"][uid] == "leader": raise UserError("The circle leader must stay in this circle for now.")
                del c["members"][uid]
            else: raise UserError("Not found.", 404)
            return self.snapshot(data, uid)
        return self.store.update(change)
