# Doctor-visit recordings

The current voice mode is a live conversation with Oracle. It streams audio for recognition, responds, and returns to listening. It does not save a recording or claim that a visit has been recorded. A listening turn is limited to one minute. Visit recording must be implemented as a separate, longer-running capture mode.

## Intended flow

1. The user asks to record a doctor's visit or selects Start visit recording.
2. Care Circle shows an explicit confirmation, then a persistent recording indicator, duration, pause, and stop controls. Starting this mode suspends the conversational assistant so it cannot speak over the visit.
3. Audio is written incrementally to a protected local file. The user can stop and save, or discard. An interrupted recording is recoverable and is not silently marked complete.
4. Saved visits appear in a library with a user-editable title, date, duration, and processing status. The user can play and delete a saved visit.
5. When cloud saving is enabled, audio uploads to a private Oracle Object Storage bucket using per-user authorization, encrypted transport, and scoped access. The app must not contain a permanent bucket credential or public object URL.
6. Oracle Speech performs long-form transcription. Care Circle can retrieve the transcript and answer later questions with citations or time references back to that visit.

## Before enabling

- Add real per-user authentication and ownership checks; the current developer connection token is for a personal prototype.
- Make recording consent, local/cloud storage choice, retention, and deletion explicit in the recording flow.
- Support on-device file protection, incremental saving, interruptions, storage-full recovery, and playback.
- Implement actual recording actions and results. The language model alone must never announce that a recording started or was saved.
- Verify long recordings on a physical iPhone, including audio route changes and locking/background behavior. The current app deliberately stops live voice when backgrounded.

All planned processing can remain in Oracle: Object Storage for private media, Speech for transcripts, Generative AI for summaries and retrieval-backed answers. No ElevenLabs dependency is introduced.
