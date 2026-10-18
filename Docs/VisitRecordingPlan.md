# Doctor-visit recordings

## Implemented

Say “start recording my doctor visit,” “please record my appointment,” or choose **Record a doctor visit** in the top-left menu. Direct requests dispatch to a recording action before the language model is called; negations and questions about how recording works do not trigger it.

Recording replaces the home screen with a cream transcript view, recording status, elapsed time and reactive burgundy finish button. The assistant does not speak during a visit. Oracle realtime Speech supplies partial and final transcript text. Final phrases remain visible as new phrases arrive; speaker identities are not inferred.

Tap the circle to finish. The app asks Oracle to finalize the last words, closes the audio file, saves the visit and returns home. **Saved visits & AI summaries** in the top-left menu contains transcripts and audio playback. **AI summary** is at the top left of each transcript. Summaries are generated through Oracle Generative AI from transcript chunks, with an explicit grounding instruction and retry on failure.

Audio is written incrementally to a CAF file. Transcripts are checkpointed during recording. Metadata, summaries and audio live in the app's Application Support/Visits directory, with iOS complete file protection and exclusion from device/cloud backups. Nothing is uploaded to Object Storage. Speech streams to Oracle; transcript text is sent to Oracle for summarization. Ordinary conversations are not persisted. Swipe a saved visit to delete audio, transcript and summary. Deleting the app removes all local visits.

The screen reminds the user to obtain everyone's agreement before recording. The display stays awake while recording. Backgrounding, an audio interruption or a storage failure stops the visit and preserves the captured material as interrupted. Local audio begins before the Oracle connection; a network/transcription failure leaves recording running and adds a visible transcript-gap warning. A process crash leaves the last checkpoint and audio file available on next launch. Do not silently label interrupted transcripts complete.

## Limits and further work

- This is a personal development prototype using one backend connection token, not a multi-user service.
- The Oracle integration is turn-based recognition, generation and synthesized speech. Tapping during a reply interrupts playback and preserves conversation history; acoustic hands-free barge-in and full duplex voice are not implemented.
- Realtime transcripts do not identify Doctor/Patient automatically. Oracle file-based diarization would require a separate upload and processing workflow; never fabricate speaker names.
- Network failures preserve captured audio but do not automatically retranscribe it. No background/locked-screen recording, pause/resume, cloud backup, cross-device sync, or retrieval-backed chat is implemented.
- Verify long appointments, low storage, incoming calls, Bluetooth and acoustic behavior on physical iPhones before relying on it for a visit. Simulator tests cover recording UI, local save/reopen, playback and summary access, not clinical accuracy or long-session reliability.
