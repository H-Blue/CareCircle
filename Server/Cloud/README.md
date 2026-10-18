# Oracle-hosted prototype

The deployment script creates an isolated `Encircle` compartment with:

- A VCN and subnet, with no default inbound rules.
- An Oracle E5 Flex VM, 1 OCPU / 2 GB RAM at a 12.5% CPU baseline, when `--paid-small-server` is explicitly selected. The free A1 option is the default; it does not automatically substitute a paid server.
- A 50 GB boot volume, systemd-managed Python backend, and nginx limits. Application payload and nginx access logging are disabled.
- An instance identity that can call Generative AI chat and Speech in the Encircle compartment, plus read/create/overwrite the exact private coordinator state object. Personal Oracle signing keys stay on the developer's Mac.
- Oracle API Gateway with its managed HTTPS hostname. Only the gateway can reach the VM's application port. No SSH ingress is opened. The VM has outbound internet access for package installation and Oracle calls.
- Bearer-token authentication on health, chat, speech session, and synthesis routes, plus gateway/nginx/application rate limits. This remains a single-developer prototype; add per-user identity before making it a multi-user product.

## Deploy

Use the locally approved OCI profile and ignored `Server/.env` described in [server setup](../README.md).

```sh
Server/.venv/bin/python Server/Cloud/deploy.py
```

If free A1 capacity is unavailable, obtain the account owner's approval before selecting a paid server:

```sh
Server/.venv/bin/python Server/Cloud/deploy.py --paid-small-server
```

Deployment identifiers and endpoint are saved in `~/.oci/encircle/cloud-state.json`, outside Git. The script reuses recorded resources on retries. A server's source is installed at first boot; changing local source and rerunning this script does not update an existing VM. To deploy changed source to this stateless personal backend, use `--paid-small-server --replace-server`. This replaces only the app VM and its boot volume, preserves the gateway address and backend token, and causes a brief outage during bootstrapping. Shared recorded visits persist in the private, versioned visit bucket. The phone retains a protected pending-upload queue and playback cache; legacy recordings remain on the phone until explicitly shared. Coordinator state is stored outside the boot volume in a private, versioned Object Storage bucket and survives replacement. The compressed startup package is size-checked before the working VM is terminated.

The small paid option was approved for this prototype after Chicago A1 capacity failed in all three availability domains. Estimated basic hosting is about $8–10/month depending on storage/free allowances and usage, excluding Generative AI and Speech charges. Trial credits apply while available. This estimate is not a spending cap. Review actual usage in Oracle billing.

## Connect the developer's iPhone

After HTTPS health and a real chat request succeed:

```sh
Server/.venv/bin/python Server/configure_device.py
```

This writes an owner-only, ignored `Encircle/LocalConnection.plist`. Debug builds copy it into the local app and save the connection token into the device Keychain. Release builds receive an empty profile. This is a convenience for this developer's own prototype, not a mechanism for distributing a shared production secret. Never commit or share the local profile. Oracle account credentials are not included in it.

## Voice pipeline

1. Ordinary conversation: `POST /voice/session` authenticates the app and mints a temporary private ElevenLabs conversation token. The permanent provider key stays in `/etc/encircle.env` on the VM.
2. The official ElevenLabs Swift SDK connects directly over WebRTC, manages live speech/turn-taking/interruptions, and exposes microphone frames for local bass/treble animation. Provider audio recording is disabled; transcript retention is one day with deletion enabled.
3. An explicit recording request or the agent's native client tool disconnects ElevenLabs, releases its audio session, and opens the local doctor-visit recorder.
4. Visits stream 16 kHz PCM to Oracle realtime Speech using `/speech/session`. During capture, protected audio and transcript checkpoints are saved in the phone’s circle-scoped upload queue. Finishing uploads the transcript through session-authenticated `/visits/save`, requests a grounded Oracle summary, and resumes compressed audio parts into private Object Storage. Member playback and metadata requests are authorized against current circle membership.

The gateway includes `/voice/session` alongside the existing Oracle routes. Ending, backgrounding or audio interruptions stop ordinary conversation. A failed visit-transcription connection leaves local visit audio recording active with a visible gap warning. Legacy synthesis remains available to older builds.

`GET /appointments` is also authenticated and serves the persistent synthetic [scheduling feed](../../Docs/MockAppointments.md), initially seeded once from the fixture. It contains three synthetic appointments, not real patient records. Reading it does not send messages; appointment creation/update events wake the coordinator.

## Verification

The Swift app builds for the simulator; signal checks use real frequency-separated test tones. Backend tests cover authentication, message validation, scoped speech-session response shape, request bounds, and private error handling. Live service checks use a synthetic non-sensitive greeting to verify Oracle TTS and realtime transcription. A physical iPhone is still needed to assess microphone gain, Bluetooth routing, acoustic echo, and end-to-end conversational latency.

## Removing the prototype

Use the resource identifiers in the local state file to locate the dedicated Encircle resources in OCI. Remove the API deployment/gateway, server and boot volume, scoped policy/dynamic group, and network resources when no longer needed. Visit recordings stay on the iPhone. The coordinator bucket contains private contact information, messages, and assignments, including historical versions; review/export those before removing the bucket. Do not remove unrelated account resources or the local signing key used for administration without reviewing their usage.

## Persistent coordinator

See [coordinator operation and limitations](../../Docs/CareCoordinator.md). The deployment creates/reuses private versioned Object Storage, adds narrowly scoped object permissions, installs the pinned Twilio SDK, and exposes authenticated coordinator/appointment routes plus signed Twilio webhooks. `--prepare-only` prepares storage/IAM without replacing the server. The gateway permits callback bursts; nginx keeps normal app traffic at 2 requests/second and Twilio webhooks at 10/second, while authenticated POST calls remain capped at 30/minute.

Only the authorized own-number demo can auto-activate after Twilio approval. Set the private sender/account/allowlist fields in the ignored server environment; leave `TWILIO_SMS_APPROVED=0` for verification checks. `TWILIO_AUTO_ENABLE_DEMO=1` enables the approved activation flow; `TWILIO_PHONE_NUMBER_SID` identifies the sender to check. Keep the circle in `paused` mode to prevent automatic activation. Storage/version/request charges are additional usage charges.

## User accounts

`prepare_users.py` prepares the separate paid Oracle NoSQL account table and Twilio Verify service. Deployment includes the account routes and grants the VM row read/write access to that table only. See [phone sign-in and circle membership](../../Docs/UserAccounts.md) for setup, costs, trial restrictions and data isolation. No real user is created and no text is sent during provisioning.

## Shared visit storage and deployment bundles

The dedicated `encircle-visits` bucket is private and versioned. The VM can list/read/create/overwrite its objects, but cannot make public links or purge versions through the app. Every member-facing route checks a phone-verified user session and current circle membership. The account table now reserves 256 read units and 128 write units (1 GB storage) to support repeated membership checks and concurrent account updates; preparation waits for Oracle to actually apply that capacity. These increased database charges, storage/request/transfer charges and AI usage are additional to VM hosting.

Source is packaged into a content-addressed tar archive in the existing private coordinator bucket under `deploy/`. Startup metadata holds the small bootstrap and private environment. After installing the pinned Oracle SDK, the VM downloads only that private source object using its instance identity, verifies SHA-256, rejects unsafe tar members, and installs it. No keys or environment files are included in the source archive. This avoids growing past OCI’s startup-metadata limit as the backend expands.

See [recording behavior and migration](../../Docs/VisitRecordingPlan.md). `check_visits.py` runs a live, admin-authorized smoke test using temporary synthetic accounts and recordings, never sends SMS or records consent, and cleans up exactly its own rows/object versions. The old coordinator/scheduling demo remains separate from recorded-visit circles.
