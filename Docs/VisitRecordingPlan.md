# Doctor-visit recordings and circle sharing

Sign in in **Menu → Your account**, then create or join a circle. A single circle is selected automatically. If you have several, open the desired circle and choose **Use this circle for visit recordings**. The appointments menu and recording screen show the destination circle.

Say “start recording my doctor visit” or “please record my appointment.” Recording opens the cream live-transcript screen. The agent disconnects and does not speak during a visit. Oracle realtime Speech supplies partial and final text; speaker identities are not guessed. A sign-in and selected circle are required for new shared recordings. Obtain everyone's agreement before recording.

Tap the recording circle to finish. The app finalizes the last words, closes the audio file and returns home. The finished transcript uploads to private Oracle Object Storage, and Oracle generates a brief, everyday-language summary from the captured words and clinician-stated next steps. Every current circle member can open the transcript and **AI summary** from the appointments menu. Shared recordings can also be played. Pull down to refresh; while the app is open and not recording, it checks for updates about every 15 seconds.

## Cloud storage and recovery

- Oracle is the authoritative store for shared visits. The iPhone keeps a protected, backup-excluded recording/checkpoint queue until upload succeeds, and a protected metadata/playback cache for display. Temporary local files are still necessary for recording, recovery and playback.
- Audio is captured incrementally as CAF, then exported to compressed M4A for upload when possible. If conversion fails, the original remains eligible for upload. The original and upload copy are removed only after Oracle verifies the entire uploaded file's SHA-256 checksum and acknowledges it. Transcripts and summaries can become visible before audio finishes uploading.
- Uploads use resumable 1 MiB parts over the authenticated HTTPS API, not public object links. A retry skips already uploaded parts. Failed integrity checks get a fresh immutable upload generation. A failed upload keeps the phone's original and shows a retry message. Uploads resume when the app is opened/active; guaranteed background upload is not implemented.
- Backgrounding, incoming audio interruptions or storage failures stop recording and preserve an interrupted visit. A process crash is recovered from its last protected checkpoint and captured audio when that circle is reopened. Transcription failures are flagged; captured audio is not automatically retranscribed.
- Existing recordings from before this change remain on the phone. After selecting a circle, choose **Share older phone recordings**, select a recording and confirm the destination. It uploads audio, transcript and any existing summary; the original legacy copy is preserved. Old recordings are never silently assigned to an arbitrary circle.

## Access and archive behavior

Accounts and memberships live in Oracle NoSQL. Every cloud metadata, audio-part and summary request checks the current session and circle membership. Knowing a visit ID is insufficient. A leaving member loses cloud access, including future playback/download requests. Already downloaded data cannot be remotely recalled from someone's device.

Only the recorder can change a transcript or upload its audio. Every circle member can read visits and request a missing summary. Archiving hides a visit for that member only, including across their devices; it does not remove it for others. Only the recorder or leader may delete a shared visit. Deletion hides it from all circle API reads; private Oracle bucket versions and uncommitted upload parts may remain for administrative retention/recovery. It is not an immediate physical purge.

The separate synthetic scheduling feed, calendar transport plan and Twilio coordinator remain the original demo system; recorded-visit sharing does not automatically connect a new circle to transport messaging.

## Limits and validation

Recorded text is bounded to 900 KB per visit and audio to 2 GiB per upload. Lists paginate and cap each response below the gateway payload limit. Uploads/downloads are streamed in bounded parts; files are never made public. AI summaries use bounded chunks, explicit grounding instructions and stale-transcript checks. A saved transcript remains available when summary generation fails. A pending summary interrupted by a server restart can resume when the circle list is reopened.

Backend tests cover member/outsider isolation, creator-only editing, idempotent saves, personal archives, concurrent preference changes, resumable audio, full-file checksum failure/recovery, membership revocation, summary sharing and deletion. The simulator test signs in as two synthetic users, uploads a visit as one, then reads the transcript/summary and plays downloaded audio as the other. The admin-run live test uses temporary synthetic identities, checks the actual Oracle APIs and inference service, and removes its fixtures and stored object versions.

Physical-device long visits, low storage, acoustic accuracy, Bluetooth and incoming-call behavior still need field validation. Background/locked-screen recording, automatic audio retranscription, speaker diarization and retrieval-backed conversational memory are not implemented.
