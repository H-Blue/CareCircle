# Apple Calendar and transport

Encircle uses native EventKit on iOS 17 and later. Open the top-left menu, tap the calendar icon, enter the name of the person you care for, and tap **Connect Apple Calendar**. Allow access to all calendar events when iOS asks. Initial connection uses the phone’s default writable calendar; the calendar picker lets you choose a different writable calendar and move Encircle’s events there with **Save & sync calendar**. Choose an iCloud calendar for Apple’s normal cross-device synchronization.

Installing the app alone cannot grant calendar permission. No Apple account password, CalDAV credential, or extra cloud service is needed. Full Calendar access is used to find and update existing Encircle events without repeatedly adding copies. Unrelated events are never uploaded to the backend or edited.

The app reads the authenticated Oracle `/appointments` feed. The current three records are explicitly synthetic: November 3, 2026, 5–7 PM; November 13, 2–7 PM; December 2, 8 AM–noon, all America/Chicago. Calendar times are saved as absolute instants with the source timezone, and titles include `(Demo)` so they aren’t mistaken for a real hospital schedule.

Tap an appointment in **Calendar & transport** to enter comma-separated names under **Taking them** and **Not taking them**. Save the details to update event notes. A name cannot appear in both lists. Empty fields are represented as unassigned/not recorded, rather than assumed agreement or refusal.

Example event notes:

```text
[Encircle]
Care recipient: Demo Care Recipient
Transport: Assigned
Taking: Alex
Not taking: Jordan
Demo appointment — synthetic scheduling data.
[/Encircle]
```

Encircle owns only that notes block; text added outside it is retained during updates. Stable appointment URL markers and locally stored EventKit identifiers let it update its own events. An EventKit identifier lookup is verified against the marker before an event is modified. A bounded marker search handles identifiers that change after calendar account synchronization. Calendar links open the app’s calendar connection screen.

After connection, sync runs when the app opens or returns to the foreground, when **Save & sync calendar** is tapped, and when transport details are saved. It does not run continuously while iOS has suspended the app. This prototype handles the booked appointments in the demo feed; cancellation/deletion reconciliation and real hospital scheduling adapters are not implemented yet. **Pause calendar updates** stops future automatic updates and keeps existing calendar events.

The care recipient’s display name, transport names, cached feed and event mapping are stored with complete file protection in the app’s local Application Support directory, excluded from backups. They aren’t sent to Oracle, ElevenLabs or Twilio. The selected Apple calendar stores event titles and notes according to its own account and sharing settings. Selecting a shared calendar can make those details visible to that calendar’s members. No invitations or messages are sent by this integration.

This is one care-recipient connection per app installation. Transport entry is local to this phone; there is no family sign-in, shared assignment database, availability detection, automatic acceptance, or messaging workflow yet. A shared Apple calendar can display its events to existing members, but the app does not create or administer those memberships. Removing the app does not remove previously saved calendar events.

Validation includes a real EventKit integration test on the iPhone simulator: cloud schedule retrieval, permission handling, native saves, exact start/end and notes checks, repeat-sync duplicate checks, transport editing, and persistence/re-sync after relaunch. A physical phone is still needed to verify the user’s particular iCloud or other calendar account.

## Cloud transport confirmations

The [Oracle coordinator](CareCoordinator.md) now adds separate outbound and return coverage to the appointment feed. Calendar notes include confirmed driver names, declines, and waiting/review statuses. Manual names remain clearly labeled local notes, separate from SMS confirmations. Synthetic appointment notes explicitly allow simulated confirmations. Cloud coordination runs while the app is closed; Apple Calendar notes refresh only when Encircle runs, including polling while the coordinator screen is visible.
