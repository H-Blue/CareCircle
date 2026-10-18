# Oracle connection

This is a **personal development bridge**, not a public production service. The Swift app calls this server; this server signs Oracle requests with the official OCI SDK. Oracle credentials never go into the app. No chats are written to disk or request logs. Oracle's own service processing and retention terms still apply.

## Account setup

Use an OCI identity authorized to call Generative AI in the selected compartment. Prefer a dedicated service identity with only `use generative-ai-chat` in the Encircle compartment. Do not grant tenancy administrator access to a deployed backend.

Register an API signing public key with that identity and save its private key and OCI config **outside this project**, normally under `~/.oci/`. Restrict the private key to your user (`chmod 600`). Oracle Console > User settings > Tokens and keys > API keys provides the configuration details. Creating this credential requires the account owner's approval.

In Generative AI > Chat, select a compartment and model. **View code** shows the compartment OCID, model OCID and service endpoint. The current account was inspected in **US Midwest (Chicago)** and the default playground model was **cohere.command-a-03-2025**. Listing a model does not verify inference permission or billing eligibility.

## Run locally

On this Mac, the approved Oracle signing key and profile are stored in `~/.oci/encircle/` with owner-only permissions. Local account values and the app connection token are in the ignored, owner-only `Server/.env`. Live inference with Cohere Command A in Chicago was verified during setup. These machine-specific files are deliberately absent from GitHub.

Once the environment is configured, build and connect the simulator in one command:

```sh
Server/.venv/bin/python Server/run_simulator.py
```

This starts the bridge if needed, builds and launches the app, and saves its local connection token in the simulator Keychain. The configuration shortcut exists only in Debug simulator builds. It does not put Oracle credentials in the app. The bridge remains running for local development; stop the `Server/server.py` process when finished.

For a fresh checkout, perform the following setup first:

```sh
python3 -m venv Server/.venv
Server/.venv/bin/pip install -r Server/requirements.txt
cp Server/.env.example Server/.env
```

Fill in `Server/.env` with the compartment OCID, model OCID, and a randomly generated app connection token of at least 32 characters. Use `OCI_CHAT_FORMAT=COHERE` for Cohere Command A, or `GENERIC` for supported models using Oracle's generic Chat API. Keep the OCI config and private key on the server. Do not use the Oracle private key as the app connection token.

```sh
Server/.venv/bin/python Server/server.py
```

In the **iPhone simulator**, open the app's menu > **AI connection**, enter `http://localhost:8787` and your app connection token, then **Save and check connection**. This checks the bridge; send a simple non-sensitive message to verify Oracle inference separately. The app keeps the app token in the iOS Keychain.

On a **physical iPhone**, use the [Oracle HTTPS deployment](Cloud/README.md). The app requires HTTPS outside the simulator. `Server/configure_device.py` creates a private local Debug connection profile after deployment; rerun the app from Xcode to install it. The cloud server uses its instance identity rather than a personal Oracle signing key. Add per-user authentication before distributing a multi-user production app.

## App behavior

The iPhone uses ElevenLabs for live conversation, Oracle realtime Speech for doctor-visit transcripts, and Oracle chat for short grounded summaries. Visit recordings remain on the phone. See the [app overview](../README.md) and [persistent coordinator](../Docs/CareCoordinator.md) for current behavior.

## Mock appointments

Authenticated `GET /appointments` returns the three synthetic 2026 appointment slots hosted on Oracle. See [feed details](../Docs/MockAppointments.md) for dates, timezone and response fields. This is a persistent development scheduling feed; Epic is not connected. Creating/updating an appointment wakes the transport coordinator. The app can sync its feed and separate direction confirmations into Apple Calendar.

## Verify

```sh
cd Server
.venv/bin/python -m unittest -v
```

These checks use a stubbed Oracle response. Live account verification is separate and must succeed before calling the integration connected.

Oracle references: [SDK configuration](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/sdkconfig.htm), [Generative AI SDK](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/generative_ai_inference.html).


## ElevenLabs conversation sessions

For the live voice agent, add a restricted `ELEVENLABS_API_KEY` to the private `Server/.env` and run `Server/.venv/bin/python Server/configure_elevenlabs.py`. This creates/updates a private Encircle agent and saves `ELEVENLABS_AGENT_ID` to the same ignored file. The setup utility uses the standard library; the production backend uses pinned OCI and Twilio SDKs. The key needs ElevenAgents management and voice-read access for setup. The current key was capped at 10,000 credits per refresh period by the account owner’s approval.

Deploy after setup so the VM receives the private key and agent ID. `POST /voice/session` requires the existing Encircle bearer token and returns only a temporary ElevenLabs conversation token. The iPhone SDK uses WebRTC for live audio; Oracle credentials and the ElevenLabs permanent key never reach the phone. Keep provider debug logging disabled. Missing provider setup returns an explicit error; it does not silently fall back to Oracle TTS.

Visit transcription still uses `/speech/session` and Oracle. Saved-visit summaries still use `/chat`. Legacy `/speech/synthesize` remains for compatibility with earlier developer builds; the updated app no longer calls it for ordinary conversations.
