# Encircle

The Oracle backend also provides an authenticated [mock scheduling feed](Docs/MockAppointments.md) with three synthetic appointment slots for upcoming calendar and messaging integration work.

[Apple Calendar integration](Docs/AppleCalendar.md) adds those slots to a selected calendar and keeps care-recipient and transport details in event notes. Open the menu’s calendar icon to connect. Calendar permission and the care recipient’s name are required once; subsequent updates run when the app is active.

A native SwiftUI iPhone and iPad starter app based on the supplied sketch.

## Open and run

1. Open `Encircle.xcodeproj` in Xcode.
2. Select the **Encircle** scheme and an iPhone simulator.
3. Press **Run** (Command-R).

Verified with Xcode 27.1; targets iOS 17 or later. To run on a physical iPhone, choose your team under **Signing & Capabilities**, then select your device. A simulator does not require a development team.

## Included

- Cream home screen, three-line menu, welcoming opening line, and burgundy speak button.
- An in-place voice screen: the menu disappears and the two-layer circle lifts when tapped.
- Microphone-driven bass movement in the center and treble movement in the outer layer.
- ElevenLabs live conversational voice through the native Swift SDK, with echo processing, speech interruptions, microphone pause/resume, and a private agent.
- Oracle realtime transcription for doctor visits and Oracle Generative AI for visit summaries.
- Oracle connection settings; the server connection token is stored in the iOS Keychain.
- Doctor-visit voice commands, live transcript screen, protected local audio/transcript saving, playback and Oracle AI summaries.
- SwiftUI previews in `ContentView.swift`.

Home starts with a local greeting. After a visit, that space prepares and displays a short AI recap in everyday language, with a link to the appointment and a “Got it” dismissal. The recap focuses on the recorded discussion and clinician-stated next steps; incomplete transcripts are flagged. Tap the circle to connect and begin listening. The agent stays silent until you speak first. Speak naturally and pause for a reply; you can interrupt by speaking. Tap while listening to pause/resume the microphone, or tap during a reply to interrupt. The same session retains context across turns. Formatting and supported expressive tags are removed from displayed text. **End conversation** stops the microphone; backgrounding the app and audio interruptions also end the session. Ordinary voice conversations are processed by ElevenLabs and its configured conversation model. Visit audio streams to Oracle for transcription, and transcript text goes to Oracle for summaries. Ordinary conversations are not saved as visit recordings.

The approved Oracle deployment uses a small E5 burstable server behind Oracle API Gateway HTTPS. A private local connection profile is included only in this developer's Debug builds and installs the server connection token into the iOS Keychain. Oracle signing keys are never embedded. Fresh checkouts need their own setup; see [Oracle setup](Server/README.md) and [cloud deployment](Server/Cloud/README.md).

Say **“start recording my doctor visit”** to begin a recording and open the live transcript screen. Tap the recording circle to finish and return home. The top-left menu lists appointments by date, with **Latest appointment** first. Tap an appointment to reopen its transcript; each transcript has an **AI summary** button in the top left. The three menu strokes expand into full-width appointment rules as the home screen fades. Swipe left on a visit row to reveal **Archive**, or swipe left on its transcript to archive it. Archived recordings stay on the device and can be reopened or restored from the archive icon at the top of the menu. Audio and transcripts stay on this device, excluded from backups. Obtain everyone’s agreement before recording. Keep the app open; interruptions stop and preserve the captured visit. Speaker names are not guessed. See [recording details and limitations](Docs/VisitRecordingPlan.md).


## ElevenLabs setup

The app uses the official ElevenLabs Swift SDK 3.4.0 with LiveKit 2.18.0, pinned through Swift Package Manager. Xcode resolves the packages when opening the project. Debug builds compile the active device architecture so app and package architectures match.

The Oracle backend exposes authenticated `POST /voice/session` to mint temporary tokens for a private ElevenLabs agent. The permanent ElevenLabs key stays in the server environment, never the iOS bundle or Git repository. Add `ELEVENLABS_API_KEY` to the ignored `Server/.env`, run `Server/.venv/bin/python Server/configure_elevenlabs.py`, and deploy the updated server. The setup utility creates or updates the existing configured agent and saves its ID privately.

The agent uses Sia - Counselor & Friend (`CUvmi6RSy4BQr6vnMyEw`) with Eleven Flash v2 to preserve the professional voice clone, 0.9× speech speed, Scribe realtime, Gemini 3.8 Flash, automatic turn-taking, and a native `start_visit_recording` tool. Playback uses a softer 0.6 gain. Local direct-command detection also opens the recorder. The assistant session fully disconnects before the recorder claims the microphone. No Oracle voice fallback silently substitutes the previous voice stack.

Provider audio recording is disabled. ElevenLabs transcript retention is configured to one day with transcript/PII deletion enabled; this is not Enterprise Zero Retention Mode. Local visit recording storage remains unchanged. The prototype agent allows one concurrent session, up to 30 sessions per day and 30 minutes per conversation. The approved provider key has a 10,000-credit cap per credit refresh period; it is not a dollar spending cap. Account subscription billing is managed separately by the account owner.

The live UI integration test `testElevenLabsRecordingToolOpensRecorder` requires a configured private backend and developer connection profile. In Debug only, it uses the provider's text-input API with a fixed synthetic recording request to exercise the actual model tool and native handoff. Other tests cover visit persistence/playback and ordinary voice mode transitions. Simulator builds bypass the Simulator’s unsupported hardware voice-processing unit; physical iPhones retain native echo processing. Physical-device acoustic and Bluetooth checks remain necessary.

## Event-driven care coordination

Oracle now hosts a persistent transport coordinator for the synthetic appointment feed. Open the menu → Apple Calendar & transport → Care coordinator to see requests, separate outbound/return coverage, and messages. In test mode, simulation controls never send SMS. The approved own-number demo can automatically start texting after Twilio approves the toll-free sender and verifies the trial recipient; it is restricted to the owner’s number with a 20-message daily limit. Calendar notes refresh when the app runs. See [workflow, setup, verification, and limits](Docs/CareCoordinator.md).

SMS signup is available in **Menu → Apple Calendar & transport → SMS consent & preferences**. The form starts unchecked and saves a private consent receipt; withdrawing suppresses future queued messages. The same screen includes Privacy Policy and Terms & Conditions pages that can be read offline, with copyable public URLs for the corresponding Twilio verification fields. [Public signup documentation](Docs/SMSConsent.md), [SMS terms](Docs/SMSTerms.md), and [privacy notice](Docs/SMSPrivacy.md) describe the current single-owner prototype. Saving consent does not bypass Twilio approval or expand the recipient allowlist.

The Encircle rename updates existing developer installations in place. Saved visits, private connection settings, calendar events, and cloud coordinator data are preserved.

Phone sign-in and circle membership are available in **Menu → Your account**. Users can create a circle as its leader or join by invitation as family/friend. Profiles and memberships persist in Oracle NoSQL. The current Twilio trial limits sign-in to configured test numbers; existing demo appointments and recordings remain separate. See [account setup and limitations](Docs/UserAccounts.md).
