# Encircle SMS signup and consent

This public document describes the actual in-app opt-in flow for **Encircle appointment and transport messages**. It is evidence of the signup mechanism, not a public list of subscribers or consent receipts.

## Where the form appears

Open Encircle on iPhone, then **Menu → Apple Calendar & transport → SMS consent & preferences**. The same screen is linked from **Care coordinator**.

A person reads the disclosure and linked SMS Terms/Privacy Notice, enters their own name and mobile number, explicitly checks the initially **unchecked** agreement box, then taps **Save SMS consent**. The save button stays disabled until the person supplies both fields and checks the box. Checking the box alone does not submit consent. Other app features remain available without opting into SMS.

## Disclosure shown in the app

> I agree to receive automated SMS from Encircle at the phone number I provide about appointment transportation requests, ride confirmations, changes, and circle-leader updates. Message frequency varies with appointment activity. Message and data rates may apply. Consent is optional and is not a condition of purchase or use of Encircle’s other features. Reply STOP to opt out and HELP for help. I can also withdraw consent in the app’s SMS preferences. I have read the SMS Terms and Privacy Notice linked below.

Checkbox label: **I agree to receive Encircle appointment and transport texts.**

[SMS Program Terms](SMSTerms.md) · [SMS Privacy Notice](SMSPrivacy.md)

These documents are also readable inside the consent screen under **Privacy & terms**. Each page includes **Copy URL** and **Open public page** controls. For Twilio’s **Privacy Policy URL**, use the public privacy-notice link above; for **Terms & Conditions URL**, use the public program-terms link. The in-app copies are bundled with the app and remain available offline.

## Actual iPhone screenshots

This shows the running app with blank fields and an unchecked consent box. No subscriber data is published.

![Actual Encircle blank signup form and unchecked SMS consent box](images/sms-consent-form.png)

## Private consent receipt and enforcement

On explicit submission, the authenticated app sends the agreement to the Oracle backend. It records the person's name and number, server time, exact disclosure/version, source (`ios_app`), and receipt ID in private versioned storage. A current consent receipt is required before live SMS dispatch, including initial automatic activation. Old checkbox states are not reused when the screen loads.

Withdrawal is available on this screen after acceptance. It records the withdrawal and suppresses future queued messages. SMS STOP opt-outs apply to every role using that phone; app acceptance does not clear a provider STOP. Delivery already submitted to the carrier cannot be recalled. No phone number or completed consent receipt is hosted at this public URL.

## Program and current deployment

The app coordinates outbound and return rides for appointments, using explicit request codes and a leader notification after confirmation. Sample appointments and messages are marked DEMO during development. The current prototype is limited to the owner's configured number, which may represent both demo roles, and is not connected to Epic or a real patient record system. Real SMS remains subject to Twilio/carrier approval and trial recipient verification. This documentation does not assert approval or eligibility for a purely personal messaging use case.

### Example operational message (fictional data)

> Encircle DEMO: Hi Ted, can you take Terraica to the appointment on Nov 03, 2026 at 05:00 PM CST? Reply YES A1B2C3D4E5 or NO A1B2C3D4E5. STOP to opt out.

## For the verification reviewer

This is an **in-app digital opt-in form**, not a text-keyword signup campaign, verbal agreement, or QR-code flow. The form is inside the authenticated iPhone app, so the screenshots are publicly hosted here for review. The named app, disclosure, screenshots, privacy notice, and program terms describe the same program. Consent records stay private. Technical source is available in this public repository.

Disclosure version: `2026-10-18-encircle-v2`.

Twilio's guidance permits public screenshots for an authenticated app's consent flow: [opt-in evidence URL requirements](https://www.twilio.com/docs/api/errors/30509). A valid opt-in mechanism does not remove use-case eligibility requirements.
