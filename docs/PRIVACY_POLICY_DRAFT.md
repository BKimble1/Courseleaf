# Privacy policy (draft)

Draft for the public privacy page. It describes the launch build as implemented in
this repository. Re-read it against the final binary before publishing; any new
framework, SDK, network call or purchase feature changes the answers here and in
App Store Connect. Placeholders are in square brackets.

---

**[APP NAME] privacy policy** — effective [DATE]

## Summary

[APP NAME] is a notebook app for iPad. Your notes stay on your iPad. The app has no
account, no analytics, no advertising and no server of its own. It does not collect,
transmit or sell any personal data.

## What the app stores, and where

- Your notebooks, pages, handwriting, typed text, images, scanned pages, imported
  PDFs, Problem Page details, review items and search index are stored only on your
  iPad, inside the app's own storage area. They are protected by the device's
  standard data protection and your passcode.
- Settings (for example Pencil-only drawing, default paper) are stored on the device.
- The app does not read notebooks from other apps and does not upload anything.

## What leaves your iPad

Only what you send. When you export a PDF or image, share, print, or back up to a
location in the Files app (including a cloud storage folder you have set up), that
copy goes where you chose. The app does not keep a copy elsewhere and cannot access
it afterwards. Keep in mind that a cloud folder you pick is governed by that
provider's terms.

## Camera and photos

The app asks for camera access only when you choose to scan a paper page, and for
photo library access only when you choose to insert a photo or save an exported
image. Scans and photos are stored in your notebook on the iPad. You can decline;
every other feature keeps working.

## Handwriting recognition and search

Handwriting and scanned pages are recognized on the device, using Apple's on-device
text recognition, to make your notes searchable. Nothing is sent to a server for
recognition. The recognized text is stored on your iPad only and can be rebuilt or
deleted from Settings.

## Purchases

If the app offers an optional one-time unlock, the purchase is handled entirely by
Apple through the App Store. Apple processes the payment and provides the app with
a receipt that only says whether the purchase exists. The app never sees your
payment details or Apple ID, and it does not send purchase information anywhere.
Refunds and purchase history are managed by Apple.

## Analytics, crash reports and third parties

- The app contains no analytics, tracking or advertising code and no third-party
  software development kits.
- If you have enabled "Share iPad Analytics" in iOS Settings, Apple may share
  crash reports with the developer through App Store Connect. Those reports do not
  contain your notes. You control this in Settings → Privacy & Security → Analytics
  & Improvements.

## Children

The app is not directed at children under 13 and collects no information from anyone.

## Your choices and deletion

Because there is no account and no server copy, deleting your data is under your
control: delete notebooks in the app (then empty the Trash), or delete the app to
remove everything it stored. Backups you exported are yours to keep or delete.

## Changes

If a future version adds a feature that sends data anywhere (for example optional
sync or an optional AI service), this policy will be updated first, the app will
explain what is sent and to whom, and you will be asked before anything leaves the
device.

## Contact

[SUPPORT EMAIL] · [SUPPORT URL]

---

## Developer notes (remove before publishing)

Implementation facts this text relies on:

- No networking code and no `NSAppTransportSecurity` exceptions in `App/`.
- Permissions declared: `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`,
  `NSPhotoLibraryAddUsageDescription` only, each triggered by a user action.
- Recognition: Vision `VNRecognizeTextRequest` on device, English.
- Purchases: StoreKit 2 only if a product is configured; no receipt is sent off-device.
- No third-party packages (`Package.swift`, `App/project.yml`).
- App Store privacy answer: **Data Not Collected**.
