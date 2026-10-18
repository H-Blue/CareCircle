# Mock scheduling feed

The Oracle backend exposes `GET /v1/appointments` using the same bearer authentication as the app's other endpoints. It returns three synthetic appointments from `Server/fixtures/appointments.json`. There is no connection to Epic, a hospital, a real patient, or a scheduling provider.

All appointments are in **2026**, in **America/Chicago**. These dates fall in Central Standard Time (UTC−06:00).

| Date | Start | End |
| --- | --- | --- |
| November 3 | 5:00 PM | 7:00 PM |
| November 13 | 2:00 PM | 7:00 PM |
| December 2 | 8:00 AM | Noon |

The response includes `schema_version`, `source: mock_scheduler`, `is_test_data: true`, the synthetic patient ID `demo-patient-001`, and an `appointments` array. Each appointment has a stable ID, generic title, booked status, explicit start/end offsets, timezone, and test-data marker. No medical details, contact details, clinic names or clinician identities are fabricated.

This is a read-only development fixture, bundled into the server deployment so it survives redeployment from the repository. It is not a patient database. A later scheduling adapter can return this same shape from an authorized real provider. Do not replace this fixture with real patient data in Git.

The feed itself has no messaging or calendar side effects. The iOS [Apple Calendar connection](AppleCalendar.md) can now read it and save events after the user connects Calendar. The scheduled slots are separate from saved visit recordings. Twilio, iMessage, reminders, and real scheduling connections remain separate integration steps.
