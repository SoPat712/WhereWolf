# Decisions log

This log lists the decisions agents made on their own while working on WhereWolf: the numbers, behavior and features the owner did not spell out. Each entry gives the time, the decision, the reason, its commits and how to undo it. Every decision lands in its own commit or commits, so `git revert <sha>` undoes it. A device install of the reverted build undoes it on a phone.

## 2026-11-05: hold-to-scrub detents (87ff28d)

- **Asked for:** "more detents, and more spaces", with steps between and above the old four.
- **Decided:**
  - every 1–2–5 points-per-bar step;
  - the coarsest step rounded up so one ruler width covers the loaded history;
  - 48-point bands that shrink evenly to a 36-point floor;
  - a softer impact of 0.55.
- **Why:** the 1–2–5 sequence gives steps 2–2.5× apart, where the old ones were 10× apart. 48 points is about one finger width per step, and ten steps still fit above the drawer on every supported phone.
- **Undo:** `git revert 87ff28d`. That also removes the hold zoom, which shares the commit.

## 2026-11-06: hold zoom at mid detents (57e9d36)

- **Asked for:** mid detents (about 1.3–1.7 min per bar) zoomed out "so much"; "bring that in more… coarse can be far".
- **Decided:** fit the route within ±(2 + (half the visible bars − 2) × coarseness²) bars of the needle. Only the coarsest detents still fit the whole ruler.
- **Why:** squaring the coarseness keeps the map close through the middle of the ladder and widens it quickly only near the coarsest steps.
- **Undo:** `git revert 57e9d36`, or tune `ReplayRulerHold.nearBars` and the exponent in `MapMotion.swift`.

## 2026-11-06: ruler landmarks details (8d817b9)

- **Approved:** the mockup (landmarks, stop snapping, stop-to-stop buttons, Go To).
- **Decided:**
  - **Time labels** use the finest of 1 min, 5 min, 15 min, 1 h and 6 h that keeps labels 60 points apart.
  - **Snapping:** within 6 points; release after 10.
  - **Go To movement rows** are named from the speed-inferred activity, because recorded motion lives in each point's payload. Reading every payload would slow history loads.
  - **Rebuilds** triggered by newly arrived points coalesce to at most once every 30 seconds.
- **Undo:** `git revert 8d817b9`.

## 2026-11-06: Today widget (b15ebc8)

- **Why built unasked:** the relayed overnight instruction was to build features the owner would very likely approve. This was the first suggestion after comparing WhereWolf with Dawarich's iPhone app.
- **Decided:**
  - a separate "Today" widget for the small home screen size and three lock screen sizes;
  - distance uses the replay overlay's rules across the whole day;
  - points count every archived point since local midnight;
  - no new targets or identifiers.
- **Undo:** `git revert b15ebc8`, then remove the widget from the home or lock screen.

## 2026-11-06: Wi-Fi place point heartbeat and unnamed-network hold (b3b71dc)

- **Asked for:** "shouldn't it only be one point? no new point logged while same wifi?", after the route scribbled around the work Wi-Fi place.
- **Decided:**
  - the place's point saves on arrival, then every 5 minutes while matched, instead of exactly once, so the history ruler's stop, Go To and Coverage still see the visit;
  - an unreadable network name keeps the last match while fixes stay inside the place.
- **Why:** a stop needs at least 5 minutes of points, and Coverage marks gaps over 10 minutes. iOS often returns no network name in the background, which let raw indoor fixes through between points.
- **Undo:** `git revert b3b71dc`, or raise `GLWifiPlaceHeartbeatInterval` for strictly one point per visit.

## 2026-11-06: pinch ruler details (4339cf4)

- **Approved:** pinch to change the ruler's scale, flick at that scale, and a scale button with a menu (mockup boards 1, 3 and 4). Hold-and-move-up goes away.
- **Decided:**
  - a pinch changes step only 15% past the logarithmic midpoint between steps, so the scale does not flicker at a boundary;
  - the menu offers Every point, 1 minute, 5 minutes, 15 minutes, 1 hour, 6 hours and Whole history, and drops entries that land on the same step;
  - the scale lasts while the app runs and is not saved across launches;
  - the scale button shares the 18-point row under the ruler, styled like the time button, rather than a 44-point button that would make the drawer taller;
  - the hint at Live reads "Pinch for scale; hold to scrub".
- **Undo:** `git revert 4339cf4`.

## 2026-11-06: map zoom follows the ruler scale (5ae98be)

- **Asked for:** "the more pinched out you are, the more zoomed out the map should be also … since you're traveling larger distances".
- **Decided:**
  - while replay follows a point at a scale coarser than every point, the map keeps the pinch's fit after release, through drags, momentum and playback; every point returns to the user's own zoom;
  - the fit is recomputed only when the scale changes or the needle moves half a ruler width, never per frame;
  - the zoom buttons still work at a coarse scale, but the next refit takes the zoom back;
  - leaving history while zoomed by the scale lands Live at the live zoom from before history; otherwise Live keeps the replay zoom as before;
  - leaving the Tracker tab restores the user's zoom at once, and coming back reapplies the scale's zoom without animating.
- **Undo:** `git revert 5ae98be`.

## 2026-11-07: smooth ruler pinch (5ce1d5d)

- **Asked for:** "The pinch to zoom still feels so detented! any way we should have the map zoom in and out smoothly, and smoothly resize the history ruler?"
- **Decided:**
  - the bars and the following map track the fingers every frame; neighboring scales crossfade, and the ends stretch slightly instead of stopping hard;
  - release carries a fast pinch at most one scale further, then settles in 0.22 seconds and commits once;
  - pinches and settles have no haptics; the menu and VoiceOver still change scale in one step.
- **Undo:** `git revert 5ce1d5d`, which brings back the 15% threshold between steps.

## Deferred for the owner

- **Watch complication for Today:** it needs a new watch widget extension and bundle identifier, which is an Apple developer account change.
- **TestFlight upload:** it waits for the owner's own approval.
