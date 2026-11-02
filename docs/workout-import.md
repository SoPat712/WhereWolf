# Workout route import

Workout route import is a fork feature. Upstream Overland 1.4 exports its trips
to Health; it does not import routes recorded by other workout apps.

Open Settings → Integrations & Exports → Import Workout Routes. Connect Apple
Health to request read access to workouts and workout routes. This does not
request write access, start a workout, or enable Where's Health export option.
Health does not reveal whether read access was denied. An empty list can mean
there are no matching workouts, read access is unavailable, or the watch has not
finished syncing its route.

Choose a lookback of 24 hours, 7 days or 30 days. The page lists up to 100 saved
workouts, newest first. Import a route manually, or enable Import When Where
Opens. Automatic import defaults off and checks when a scene becomes active;
this version does not register HealthKit background delivery. It never queues
data for a destination automatically. Workouts without a readable route remain
retryable. Where's own workout exports are excluded to prevent feedback loops.

Imported routes live in a separate, protected SQLite collection excluded from
backups. Every valid point is retained, with original timestamps, coordinates,
altitude, speed, course and their available accuracy values. Identical points
are deduplicated, and batches are ordered by timestamp. The route preview uses
the full coordinate list. Updated Health route samples replace the local route;
unchanged sample revisions avoid rereading the coordinates. Importing does not
alter the live location, active trip, tracking policy, or Tracker replay archive.
This keeps watch routes separate from a phone left at home.

Routes remain saved until removed. Removing a local route leaves Health and
already queued/uploaded points unchanged. Automatic checks skip removed routes;
a manual import restores them and enables subsequent automatic updates.

## Sending imported points

Each imported route has an explicit Queue Points for Destination action. It
requires All Data logging or an iCloud destination and uses the existing send
interval, batching, retry and acknowledgement behavior. Imported points are
GeoJSON features tagged with the Health source app, workout UUID and a stable
point ID. The configured trip-mode server value and optional device ID are
included. No heart-rate, calorie or other workout measurements are uploaded.

The queue commits in chunks of 200 points. Queue records and per-point import
receipts commit in the same transaction. Retrying a partially queued route,
reimporting it, or retrying after uploaded points leave the queue does not
enqueue those points again. Explicit queue deletion also retains these receipts.
Changing to Only Latest logging does not prune pending imported points.

Routes may arrive after newer phone points have already uploaded. The chosen
destination must accept historical points and multiple sources; importing cannot
change a server's ordering requirements. Overlapping phone and watch records
are identified by source rather than silently overwriting either track. This
addresses the concern described in [upstream issue #65](https://github.com/aaronpk/Overland-iOS/issues/65).
Updated route geometry does not retract points already sent to a destination.

## Availability

The installed app needs HealthKit signing support and the user's read permission.
`WHERE_HEALTHKIT_ENABLED=NO` prevents Health access in limited-profile builds;
those builds can still browse previously imported local routes. Automatic
import and read-access setup are independent from workout export.

Tests use injected Health clients and disposable storage. They cover delayed
routes, replacement revisions, retained dense points, stable IDs, file failures,
removed-route handling, atomic queue receipts, retry deduplication, fractional
timestamps and separation from live tracking. Simulator tests do not establish
real watch-to-phone Health synchronization or actual permission grants.

Sources: [Reading route data](https://developer.apple.com/documentation/healthkit/reading-route-data),
[Health authorization and privacy](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data).
