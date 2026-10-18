# Care Circle SMS Program Terms

Effective October 18, 2026. Program: **Care Circle appointment and transport messages**. Disclosure version: `2026-10-18-v1`.

By entering your own mobile number, checking the initially unchecked SMS agreement box, and selecting **Save SMS consent** in the Care Circle app, you authorize automated operational messages about appointment transportation requests, ride confirmations, changes, and circle-leader updates. No marketing messages are part of this program.

Message frequency varies with appointment activity and replies. Message and data rates may apply according to your carrier plan. The current developer deployment has a shared limit of 20 outgoing messages per UTC day; a message may use multiple carrier-billed SMS segments. Delivery depends on carrier availability and sender/recipient eligibility.

SMS consent is optional. It is not a condition of purchase or use of Care Circle's other features. A saved agreement does not bypass Twilio sender verification. The current prototype is restricted to the owner's configured number and synthetic appointment data; it is not a general public signup or a hospital scheduling service.

## Stop and help

- Reply **STOP** to opt out of the program.
- You may also withdraw in **Menu → Apple Calendar & transport → SMS consent & preferences**. Future queued messages are suppressed; an already submitted message may still arrive.
- If you texted STOP, an in-app form submission does not clear the provider's opt-out. Send **START** to remove the SMS block. You must also have current in-app consent for automated coordination messages.
- Reply **HELP** for messaging instructions. General non-sensitive technical support is available through [Care Circle support issues](https://github.com/H-Blue/CareCircle/issues). Do not post private information there.

## Ride confirmations

A ride request is not an assignment. Reply `YES` followed by its request code to accept, or `NO` and the code to decline. Each direction has a separate code; accepting the outbound ride does not accept the ride home. Reply `CANCEL` and the original code to cancel your confirmed ride. Schedule changes invalidate older request codes and require a new arrangement.

Care Circle is not an emergency service. For urgent transport arrangements, contact the circle leader directly. The prototype does not guarantee that a message is delivered, read, or acted on. Treat simulated messages and synthetic appointments as development data.

See the [SMS Privacy Notice](SMSPrivacy.md) for consent records, service providers, retention, and choices. See [signup documentation](SMSConsent.md) for the actual in-app form.
