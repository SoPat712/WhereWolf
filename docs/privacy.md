---
layout: default
title: WhereWolf Privacy Policy
permalink: /privacy/
---

# WhereWolf Privacy Policy

Effective November 2, 2026

WhereWolf is developed by Josh Patra ([SoPat712](https://github.com/SoPat712)).
This policy describes the WhereWolf iOS app and its companion watch app.

## What the developer receives

WhereWolf has no developer-operated server. The app does not automatically send
your location, Health data, or usage information to Josh Patra. It has no ads,
analytics service, or tracking across other companies' apps and websites. It
includes no advertising or analytics SDKs. FMDB, its third-party database
library, works locally with SQLite.

You can choose to send information to the developer by opening a support issue
or sharing a diagnostic report. GitHub issues are public, so do not include
location history, credentials, or other private information.

## Location and storage on your device

With your permission, WhereWolf records location, including in the background if
you allow it. Depending on the available readings and settings, records include
coordinates, timestamps, altitude, speed, direction, accuracy, motion activity,
battery state, and trip information.

WhereWolf stores its pending upload queue, recent location history, active trip
geometry, and imported workout routes on the device. Trip summaries wait in the
upload queue after a trip ends. Recent history defaults to 24 hours;
you can choose a retention period from 24 to 168 hours. That limit applies to
recent history, not to the upload queue, trips, or imported workouts. Server
settings, credentials, Wi-Fi zones, and other preferences are also saved locally.
Successful delivery removes acknowledged records from the upload queue without
deleting recent history. Active trip geometry is cleared when the trip ends;
its queued summary and any Health export have separate lifetimes.

## Sending to your chosen destination

WhereWolf sends queued location records to the server address you configure. It
does not come with a developer-run destination. Once configured, sends can
happen automatically according to your settings, including in the background.
Your server can return configuration changes that WhereWolf applies.

The data sent depends on your format and settings. GeoJSON records can include
the connected Wi-Fi network name (SSID), motion activity, battery information,
trip mode, start and end times, distance, and step counts. They can also include
a device name you configure and, if you enable it, Apple's identifier for this
app's vendor. Optional tracking statistics describe acquisition settings and
can include tracking actions, their timestamps, and the latest coordinate. The
OwnTracks format sends a smaller set of location and device information.
Authentication and custom headers you configure accompany server requests.

WhereWolf also requests account information from the configured server. The
server operator receives these requests and handles the data under its own
practices. Choose a destination you trust and use HTTPS to protect data in
transit; WhereWolf also allows HTTP destinations. Deleting data in WhereWolf does not
delete copies already sent to a server.

## Apple Health and iCloud Drive

If you enable Health export and grant access, WhereWolf saves selected trips as
workouts and routes in Apple Health. It keeps local route data while preparing
and retrying those exports. Export also requests read access to find earlier
WhereWolf workouts and route records, so recovery can avoid duplicate exports.

WhereWolf imports other apps' saved Health workout routes only after you choose to
set up import and grant access. Imports keep the route's original timestamps,
source app, and workout details in a separate local collection. An optional foreground
check can find new routes and import them locally. Importing a route does not
upload it. You must explicitly queue its points for your chosen destination.
Once queued, they follow your normal sending settings, including automatic
sends and retries. Those points include route coordinates, timestamps, workout
identifiers, and source information. WhereWolf does not write imported routes back
to Health. Removing a local import does not remove the original Health workout
or copies already queued or sent.

If you select iCloud Drive as your destination, WhereWolf writes export files to
your own iCloud Drive container instead of sending the queue to an HTTP server.
Apple handles iCloud storage and synchronization. You control these files and
Health records through Apple's apps and settings; Josh Patra cannot access them
through WhereWolf.

## Motion, Wi-Fi, and notifications

Motion & Fitness access is optional. WhereWolf uses it to identify movement and
stops, support optional adaptive tracking, and count trip steps. Processing
happens on the device, but motion labels and step counts can be included in
records sent to your configured destination.

WhereWolf uses connected Wi-Fi names and access-point identifiers (BSSIDs) to match
Wi-Fi zones you configure. Zone settings and a bounded list of observed networks
are stored on the device. BSSIDs are not included in location uploads; the
network name can be included in GeoJSON records as described above. Matching a
zone can replace a recorded coordinate with that zone's configured location.
WhereWolf can also check the connection type to support Wi-Fi-only sending and
connection-return retries.

WhereWolf's tracking, upload, reminder, and trip alerts are local notifications. It
does not use a developer-operated push notification service.

## Watch, Siri, Shortcuts, and widgets

The watch companion exchanges commands and tracking status with the paired
iPhone using Apple's WatchConnectivity. It has no separate upload destination
and does not keep a location database.

WhereWolf's Siri and Shortcuts actions, widgets, controls, and Live Activities run
through app and system components on your device. They can start or stop
tracking or trips and request a send to your configured destination. The app
shares the state needed for widgets through an on-device App Group and donates
trip and tracking actions to Apple's system to support suggestions. Apple's
handling of Siri requests is governed by Apple's settings and privacy practices.

## Maps, tips, and external links

WhereWolf uses Apple Maps to load map data. Apple's handling of map requests is
described in [Maps & Privacy](https://www.apple.com/legal/privacy/data/en/apple-maps/)
and the [Apple Privacy Policy](https://www.apple.com/legal/privacy/).

Tips to support WhereWolf are processed by Apple through in-app purchases. WhereWolf
checks products, purchase results, and subscription status using StoreKit;
Josh Patra does not receive your payment card or bank details through the app.
In the US App Store storefront, the app also offers optional links to tip
Overland's creator, Aaron Parecki, through Cash App, PayPal, or Venmo. These
open external services, whose own privacy practices apply. The Venmo link
requests a public payment.

Opening support, source-code, privacy, or other web links contacts the relevant
website. These support pages are hosted by GitHub Pages, which is covered by
the [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## Diagnostics and sharing

Optional location-health logs stay on your device. They contain a limited set
of technical events, without coordinates, server addresses, or credentials,
and retain at most 200 events for seven days. Send outcomes for the current app
session are also available locally.

Builds with diagnostic collection, including TestFlight betas, can keep more
detailed reports on the device, excluded from device backups, until you choose
to share one. WhereWolf keeps the latest 100 reports from Apple's diagnostic
frameworks, covering app performance and supported diagnostic events. You can
review a report before sharing it. WhereWolf has no automatic diagnostic-report
uploader. Apple's own TestFlight feedback and system diagnostic sharing are
separate and follow your Apple settings and Apple's privacy practices.

When you use a share or export action, the recipient or app you choose receives
the selected data.

## Your choices

You can stop tracking, change the destination, disable optional features, and
change location, Motion & Fitness, Health, and notification access in iOS
Settings. WhereWolf has controls to delete pending uploads and remove local workout
imports. Deleting the upload queue does not erase recent history, trips, or
Health records. Recent history expires according to its retention setting.
Ordinary app data may be included in device backups, depending on your settings.
Deleting the app removes its local app data; separately saved server data,
iCloud files, Health records, shared exports, and device backups must be managed
where they are stored.

## Children

WhereWolf is a location-recording tool for general use and is not designed
specifically for children. It does not ask for a child's age or create user
accounts. The same permission and destination choices apply to every user.

## Changes and contact

Changes to this policy will appear on this page with an updated effective date.
For privacy questions, contact Josh Patra through a
[GitHub issue](https://github.com/SoPat712/WhereWolf/issues).

[WhereWolf support]({{ '/' | relative_url }})
