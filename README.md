# Care Circle

A native SwiftUI iPhone and iPad starter app based on the supplied sketch.

## Open and run

1. Open `CareCircle.xcodeproj` in Xcode.
2. Select the **CareCircle** scheme and an iPhone simulator.
3. Press **Run** (Command-R).

Requires Xcode 15 or later and iOS 17 or later. To run on a physical iPhone, choose your team under **Signing & Capabilities**, then select your device. A simulator does not require a development team.

## Included

- Cream home screen, three-line menu, welcoming opening line, and burgundy speak button.
- A working menu, conversation screen, on-device voice input, and optional spoken replies.
- Oracle connection settings; the server connection token is stored in the iOS Keychain.
- SwiftUI previews in `ContentView.swift`.

The opening line is currently local text. The speak button opens a conversation. Oracle credentials and a running backend are required for live AI replies; see [Oracle setup](Server/README.md). Voice input requires microphone/speech permission and on-device speech support. Review your message and tap Send to send it to Oracle through your backend.
