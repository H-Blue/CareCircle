# Encircle SMS Privacy Notice

Effective October 18, 2026. Applies to the appointment and transport SMS program, disclosure version `2026-10-18-encircle-v2`.

Encircle is a care-coordination app in development. Its current deployment has phone-verified user accounts and private circle memberships. The separate transport-message demo uses synthetic appointments and restricted recipients, with no hospital/Epic connection.

## Information used

When you explicitly opt in inside the app, Encircle privately records your name, phone number, the disclosure and version you agreed to, the server-recorded time, the source of your agreement, and a consent receipt identifier. A withdrawal is recorded with its time. The system also maintains SMS requests/replies, delivery state, opt-outs, and ride assignments needed to operate the program.

We use this information to send requested appointment/transport coordination messages, process replies, enforce consent and opt-outs, and maintain an audit record. We do not sell phone numbers or SMS consent information. Mobile information and SMS opt-in data are not shared with third parties or affiliates for marketing or promotional purposes.

Twilio processes phone numbers and message content to deliver SMS and return replies/status updates. Oracle Cloud hosts private account, coordination and consent storage. These providers process data to operate the service, not as a transfer of consent to their separate marketing programs. Phone numbers and names are not included in the Oracle transport-planning prompt. The app's separate voice and visit-recording features have their own data flow described in the project README.

## Storage and public documentation

Verified-account consent records are stored in private Oracle NoSQL and are accessible only through that user's authenticated session. The record includes the current agreement and up to 10 consent changes. It is bound to the verified sign-in number. Names and roles are visible to members of the same circle; phone numbers and consent records are not. The separate original owner-demo consent and coordination records remain in private Oracle Object Storage with historical versions and use its owner connection. None of these records are part of the public source repository or public signup screenshots. During this prototype, owner-demo audit records and storage versions are retained; user-account consent history retains the latest 10 changes. Withdrawing SMS consent stops future queued messages; it does not erase historical records or recall a message already submitted to the carrier.

The public proof page contains only documentation and blank-screen screenshots. Do not publish your completed form, phone number, consent receipt, appointment information, or messages as proof of consent.

## Your choices and support

SMS is optional and is not a condition of purchase or use of the app's other features. Reply STOP to opt out. You can also open **Menu → Apple Calendar & transport → SMS consent & preferences → Withdraw SMS consent**. If you opted out through SMS, saving the form does not clear that provider opt-out; START is required to remove the SMS block.

Reply HELP for messaging help. General technical questions can be posted to [Encircle support issues](https://github.com/H-Blue/Encircle/issues). That is a public forum: do not include phone numbers, medical information, private consent receipts, or account credentials. The app's withdrawal control is the direct way to stop future queued texts.

See [SMS Program Terms](SMSTerms.md) and [the actual signup flow](SMSConsent.md).
