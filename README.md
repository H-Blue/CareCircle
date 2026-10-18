# Care Circle

A native SwiftUI iPhone and iPad starter app based on the supplied sketch.

## Open and run

1. Open `CareCircle.xcodeproj` in Xcode.
2. Select the **CareCircle** scheme and an iPhone simulator.
3. Press **Run** (Command-R).

Requires Xcode 15 or later and iOS 17 or later. To run on a physical iPhone, choose your team under **Signing & Capabilities**, then select your device. A simulator does not require a development team.

## Included

- Cream home screen, three-line menu, welcoming opening line, and burgundy speak button.
- An in-place voice screen: the menu disappears and the two-layer circle lifts when tapped.
- Microphone-driven bass movement in the center and treble movement in the outer layer.
- Oracle realtime transcription, Oracle AI replies, and Oracle text-to-speech, with listening, thinking, and speaking states.
- Oracle connection settings; the server connection token is stored in the iOS Keychain.
- SwiftUI previews in `ContentView.swift`.

The opening line is currently local text. Tap the circle to connect and begin listening. Pause to finish a turn, or tap the circle again. After Oracle speaks its answer, listening resumes. **End conversation** stops the microphone; backgrounding the app and audio interruptions also end the session. Voice and text are sent to Oracle while the session is active. Ordinary conversations are not saved as visit recordings.

The approved Oracle deployment uses a small E5 burstable server behind Oracle API Gateway HTTPS. A private local connection profile is included only in this developer's Debug builds and installs the server connection token into the iOS Keychain. Oracle signing keys are never embedded. Fresh checkouts need their own setup; see [Oracle setup](Server/README.md) and [cloud deployment](Server/Cloud/README.md).

The doctor-visit recording and retrieval flow is planned separately in [the recording plan](Docs/VisitRecordingPlan.md). It is not active in ordinary voice mode.
