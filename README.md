# safety_app
A women's safety app that sends an emergency SMS with live location to trusted contacts in one tap, with a fake call feature, quick emergency dialing, and more.
# Women Safety App

A mobile app that helps women get help quickly in unsafe situations. With a single tap, the app sends an emergency SMS containing the user's live location to her trusted contacts, so help can reach her faster.

## Problem Statement

Women often feel unsafe while traveling or walking alone, and in an emergency they may not be able to unlock a phone, find a contact, and explain where they are. This app reduces that to one tap.

## Core Features

- **One-tap SOS alert:** sends an emergency SMS with a Google Maps link of the user's current location to all trusted contacts
- **Live location sharing:** fetches the user's real-time GPS location and includes it in the alert
- **Trusted contacts:** add, view, and delete up to 5 emergency contacts, stored securely on the device
- **Quick emergency call:** dial the emergency number directly from the home screen
- **Fake call:** a realistic incoming-call screen that helps the user leave an uncomfortable situation
- **Cancel countdown:** a short countdown before the alert is sent, to prevent accidental alarms

## Planned Features

- Shake-to-trigger SOS, for use without unlocking the phone
- Safe-journey timer that alerts contacts automatically if the user doesn't check in
- Nearby police stations and hospitals on a map
- Audio recording during an emergency
- Crowd-sourced unsafe-area reporting

## Tech Stack

| Area | Technology |
|---|---|
| Framework | Flutter (Dart) |
| Local storage | shared_preferences |
| Location | geolocator |
| Calls and maps | url_launcher |
| SMS | Telephony plugin (Android) |
| Development | GitHub Codespaces |

## Privacy

- Contacts are stored only on the user's device
- Location is read and shared only when the user triggers an SOS
- No account or personal data is collected

## How to Run

```
flutter pub get
flutter run
```
SMS sending works on a real Android phone only.

## Disclaimer

This app is a supplementary safety tool. In a real emergency, always contact local emergency services as well.

## Author

thanuja , woxsen , 1st year 