# Persistent care coordinator — personal demo

The Oracle server hosts an event-driven coordinator. It is software with durable memory and explicit rules, not a self-aware agent. It runs while the iPhone app is closed; Oracle AI reviews the missing transport needs once per appointment revision. Verified workflow rules choose consented recipients, send requests, process explicit answers, and notify the circle leader. If inference fails, the coordinator records that it used its rules instead.

## Current circle

The private cloud configuration contains fictional patient Terraica, circle leader Harry, and fictional family friend Ted. Both roles use the owner's one approved phone number. No real patient records or third-party contacts are involved. The three existing November/December 2026 appointments seed the persistent database once; editing the database is not undone on restart. All of these appointments and their messages are marked DEMO.

The sender is a Twilio trial toll-free number. Toll-free verification must be approved and the trial destination must be verified before live messaging. The owner authorized automatic activation for this own-number demo: the worker checks Twilio every five minutes and only switches from test to live after approval, recipient verification, matching the one-number allowlist, a current privately saved in-app consent receipt, and synthetic-data checks. A deliberately paused circle remains paused. The SMS consent screen starts unchecked and records the actual disclosure/version and server time on explicit submission. Withdrawal suppresses queued texts and flags existing driver arrangements for review. Test confirmations are cleared when switching to live, so simulations never become real arrangements. Permanent Twilio credentials stay in ignored owner-only local settings and root-only cloud configuration, never the iPhone or Git.

## Event flow

1. An authenticated scheduling adapter creates or updates an appointment with a stable ID through `POST /appointments`. Identical repeated updates have no effect. This is the adapter boundary for future scheduling software; Epic is not connected.
2. The worker wakes immediately after an update. A 30-second timer catches missed wakeups and expired requests. Oracle reviews known facts; names and phone numbers are not included in that planning prompt.
3. It creates separate requests for the ride **to the appointment** (appointment start time) and the ride **home** (end time). These times are appointment/return targets, not estimated pickup or travel times; location, routing, and travel buffers are not implemented.
4. Each message asks for `YES <code>` or `NO <code>`. A code identifies one appointment revision, direction, and recipient. A bare “yes” cannot confirm an ambiguous ride. A rate-limited clarification is queued instead. Confirmation of one direction never covers the other.
5. A YES from the matching phone assigns that direction and queues a leader notice. A NO, delivery failure, or four-hour unanswered request advances to the next eligible contact; exhausting contacts escalates to the leader. `CANCEL <code>` cancels that person's confirmed ride and asks for coverage again.
6. Schedule changes invalidate older offers and confirmations, notify the leader (and an old driver with a different number), and create a new plan. Old replies cannot assign a changed or cancelled appointment. A confirmed driver opting out is flagged for direct review.

The request queue is written before calling Twilio. A timeout or interrupted send is **uncertain**, not automatically retried: the message may already have been accepted. A signed provider callback can resolve acceptance after a crash; otherwise the leader is asked to review. Delivered messages and confirmed rides are distinct states. Leader notification failures remain visible in the queue; there is no guarantee that a leader has read a notice.

## Limits and controls

- Outgoing SMS is restricted at the server to the owner's approved number. A maximum of 20 outgoing messages per UTC day includes requests, clarification, and leader notices; claimed or failed attempts consume the allowance. A message may use multiple billable SMS segments. This is a message-count guard, not a dollar cap.
- STOP and related opt-out words suppress future queued messages to that number across both demo roles. START re-enables the number; editing configuration does not silently clear an opt-out. Provider opt-out controls still apply.
- Twilio callbacks bypass app bearer authentication and require the official SDK's signature validation against the exact public HTTPS URL, all form fields, and the expected account and phone direction. Incoming MessageSid deduplication prevents replayed confirmation/notification side effects.
- App/admin endpoints require the existing prototype bearer token. This is a single-owner prototype, not per-user authorization. Do not distribute that shared token as a multi-user product.
- The private, versioned Oracle Object Storage object uses conditional ETag writes, preserving transactional state through concurrent callbacks and VM replacement. The server identity can only read/create/overwrite that exact object, not delete versions or expose the bucket. Storage/version/request charges may apply. There is no automatic historical-version deletion policy yet; versions contain private phone and message data.
- Worker errors keep state intact. The authenticated coordinator screen shows its latest plans and message states. A heartbeat is persisted every five minutes. There is no external outage alerting service yet.

## App and Apple Calendar

Open the menu → Apple Calendar & transport → Care coordinator. Test mode shows simulated messages and explicit simulation controls; these never send texts. The app shows separate direction statuses and confirmed names. Local manual notes remain separate from cloud SMS confirmations.

Calendar notes refresh on foreground/open and while the coordinator screen is visible. The cloud coordinator keeps running while the phone is closed, but **Apple Calendar notes do not update until Encircle runs again**. Push/background calendar delivery, iMessage automation, geofencing/doctor-office arrival prompts, and escalation by voice call are not implemented. iMessage is not used by the SMS coordinator.

## API

- `GET /appointments`: authenticated persistent feed with optional `coordination.outbound` and `coordination.return` objects (`state`, `driver`, `not_taking`).
- `POST /appointments`: authenticated stable `id`, `title`, aware ISO8601 `start`/`end`, `time_zone`, `status` (`booked`/`cancelled`), `is_test_data` boolean. Repeated identical payloads are idempotent.
- `GET /coordinator`: authenticated plans, redacted role/contact metadata, activity, and recent queued messages.
- `POST /coordinator/check`: authenticated wakeup.
- `POST /coordinator/configure`: authenticated full circle setup (`mode`, `patient_name`, consented `leader`/`contacts`, `daily_limit`, `allow_demo_sms`). Phone numbers must be E.164. This does not expand the server's own-number allowlist.
- `POST /coordinator/simulate`: authenticated, **test mode only**, `code` and `reply` (`YES`, `NO`, `CANCEL`).
- `POST /twilio/inbound`, `/twilio/status?job=…`: Twilio-signed form webhooks; no message payload logging.

## Verification

Run `Server/.venv/bin/python -m unittest discover -s Server -v`. Tests exercise authentication, signed/tampered callbacks, duplicate incoming messages, individual directions, stale schedule revisions, opt-outs, timeouts, uncertain sends, claim recovery, caps, and simulated/live separation. Live cloud verification must separately check Oracle inference, private state persistence, signed HTTPS callback routing, and the app's EventKit notes. A successful simulation does not prove carrier delivery; live end-to-end testing requires an approved sender and a real reply from the owner's phone.

Official references: [Twilio webhook validation](https://www.twilio.com/docs/messaging/guides/webhook-request), [toll-free verification](https://www.twilio.com/docs/messaging/compliance/toll-free/console-onboarding), [sole proprietor registration-number exemption](https://www.twilio.com/en-us/changelog/business-registration-numbers-required-for-toll-free-messaging-p), [Oracle Object Storage versioning](https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/usingversioning.htm), [Oracle object-level permissions](https://docs.oracle.com/en-us/iaas/Content/Identity/policyreference/objectstoragepolicyreference.htm).

## In-app SMS consent

Open Menu → Apple Calendar & transport → SMS consent & preferences. An authenticated `GET /sms/consent` returns the current program disclosure, links, and the private owner receipt if present; authenticated POST accepts an explicit current-version agreement or withdrawal. The server checks the configured owner phone, not an arbitrary submitted destination. These records share the private coordinator object and its version history. Existing chat/configuration permission alone cannot pass the new live-dispatch gate. See [public signup evidence](SMSConsent.md), [SMS terms](SMSTerms.md), and [privacy notice](SMSPrivacy.md). The proof page is not an opt-in form for the general public and publishes no completed receipts. Twilio still decides sender/use-case eligibility.
