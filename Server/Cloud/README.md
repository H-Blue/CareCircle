# Oracle-hosted prototype

The deployment script creates an isolated `CareCircle` compartment with:

- A VCN and subnet, with no default inbound rules.
- An Oracle E5 Flex VM, 1 OCPU / 2 GB RAM at a 12.5% CPU baseline, when `--paid-small-server` is explicitly selected. The free A1 option is the default; it does not automatically substitute a paid server.
- A 50 GB boot volume, systemd-managed Python backend, and nginx limits. Application payload and nginx access logging are disabled.
- An instance identity that can call Generative AI chat and Speech only in the CareCircle compartment. Personal Oracle signing keys stay on the developer's Mac.
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

Deployment identifiers and endpoint are saved in `~/.oci/carecircle/cloud-state.json`, outside Git. The script reuses recorded resources on retries. A server's source is installed at first boot; changing local source and rerunning this script does not update an existing VM. To deploy changed source to this stateless personal backend, use `--paid-small-server --replace-server`. This replaces only the app VM and its boot volume, preserves the gateway address and backend token, and causes a brief outage during bootstrapping. Saved visits live on the iPhone. Do not use replacement if server-side persistence is added later without first implementing migration/backup.

The small paid option was approved for this prototype after Chicago A1 capacity failed in all three availability domains. Estimated basic hosting is about $8–10/month depending on storage/free allowances and usage, excluding Generative AI and Speech charges. Trial credits apply while available. This estimate is not a spending cap. Review actual usage in Oracle billing.

## Connect the developer's iPhone

After HTTPS health and a real chat request succeed:

```sh
Server/.venv/bin/python Server/configure_device.py
```

This writes an owner-only, ignored `CareCircle/LocalConnection.plist`. Debug builds copy it into the local app and save the connection token into the device Keychain. Release builds receive an empty profile. This is a convenience for this developer's own prototype, not a mechanism for distributing a shared production secret. Never commit or share the local profile. Oracle account credentials are not included in it.

## Voice pipeline

1. Ordinary conversation: `POST /voice/session` authenticates the app and mints a temporary private ElevenLabs conversation token. The permanent provider key stays in `/etc/carecircle.env` on the VM.
2. The official ElevenLabs Swift SDK connects directly over WebRTC, manages live speech/turn-taking/interruptions, and exposes microphone frames for local bass/treble animation. Provider audio recording is disabled; transcript retention is one day with deletion enabled.
3. An explicit recording request or the agent's native client tool disconnects ElevenLabs, releases its audio session, and opens the local doctor-visit recorder.
4. Visits stream 16 kHz PCM to Oracle realtime Speech using `/speech/session`. Full audio and transcript checkpoints are saved on the iPhone. Finishing calls `/chat` for grounded Oracle summaries.

The gateway includes `/voice/session` alongside the existing Oracle routes. Ending, backgrounding or audio interruptions stop ordinary conversation. A failed visit-transcription connection leaves local visit audio recording active with a visible gap warning. Legacy synthesis remains available to older builds.

## Verification

The Swift app builds for the simulator; signal checks use real frequency-separated test tones. Backend tests cover authentication, message validation, scoped speech-session response shape, request bounds, and private error handling. Live service checks use a synthetic non-sensitive greeting to verify Oracle TTS and realtime transcription. A physical iPhone is still needed to assess microphone gain, Bluetooth routing, acoustic echo, and end-to-end conversational latency.

## Removing the prototype

Use the resource identifiers in the local state file to locate the dedicated CareCircle resources in OCI. Remove the API deployment/gateway, server and boot volume, scoped policy/dynamic group, and network resources when no longer needed. No visit data is stored on this server. Do not remove unrelated account resources or the local signing key used for administration without reviewing their usage.
