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

## 2026-11-07: route fill and live scale zoom (31f6e16, 7c2456f)

- **Asked for:** "tracks from behind are not filled in? please optimize that overall?" and "zooming out when live doesn't work! that should also zoom the map out, no?"
- **Decided:**
  - reloads change only the route sections whose points changed; the section under the marker is drawn by the app, so a gap behind the marker cannot wait on MapKit;
  - a zoom covers only the blue of up to four sections behind the marker, not the whole visible route or the dots, to keep zooming cheap;
  - at Live the scale zooms the map to the newest points around your location but draws no route, so the blue route still means history;
  - Live and history keep separate base zooms.
- **Undo:** `git revert 7c2456f` for the live zoom, `git revert 31f6e16` for the route drawing.

## 2026-11-07: coast to Live and reset the scale at Live (419bcc0)

- **Asked for:** "I just inertially scrolled to the right but it's still in recap mode!" and "going back live should zoom the user back in, and reset the pinch zoom of the ruler!"
- **Decided:**
  - a ruler settle within one pixel of the Live edge counts as Live, because momentum stops on whole pixels;
  - returning to Live from history resets the scale to every point and lands at the live zoom from before history, also after the replay camera was moved by hand;
  - a pinch at Live still zooms the live map and keeps its scale until the next return from history.
- **Undo:** `git revert 419bcc0`.

## 2026-11-07: a flick returns to Live on arrival (b53e7eb)

- **Asked for:** "it still waits for the inertia to stop before going live, is it not possible to recognize when it's just inertia vs finger holding it down?"
- **Decided:** a flick whose momentum target is the Live edge returns to Live when it reaches the edge and stops there without bouncing; a held finger still keeps the interaction, and a flick back out of the overscroll keeps browsing.
- **Undo:** `git revert b53e7eb`.

## 2026-11-08: a stop survives a silence that ends across the lot (f833b33)

- **Asked for:** "did you ever find out why the 8:04-9:11 wasn't registerd as a stop? what happened there?"
- **Decided:** a silence of at least 5 minutes followed by a fix 60–100 m away ends the stop at that fix. Closer fixes already continue a stop from a later start, and a wider rule split one evening at home into two stops.
- **Undo:** `git revert f833b33`.

## 2026-11-08: Trip tab redesign (d8e360d)

- **Asked for:** "I don't really like the trip tab! … can we make the trip start button animate? fix colors? make it feel better/easier to use?"
- **Decided:** one-tap mode buttons, a green Start Trip that becomes a red End Trip, elapsed time, distance and average speed while recording, and a breathing red dot. The timestamp chip strip was removed; the Tracker ruler scrubs trips.
- **Undo:** `git revert d8e360d` (revert ad0f6c8 first).

## 2026-11-08: open on Trip during a new trip (ad0f6c8)

- **Asked for:** "should trip tab be the default when trips are running?"
- **Decided:** yes, once per trip when the app becomes active, never while it is active or with setup showing, and never away from Trip when a trip ends.
- **Undo:** `git revert ad0f6c8`.

## 2026-11-08: first Settings switch and strip selection (0df84a7)

- **Asked for:** "on app first boot, switching from trip to settings means it takes a while for the drag handle to go away" and "switching from settings to trip jiggles things just slightly".
- **Decided:** lay Settings out behind the map for one pass a second after launch, and update the drawer strip's selection before a native-bar handoff.
- **Undo:** `git revert 0df84a7`.

## 2026-11-08: stop labels and no-data marks on the ruler (913fb7a)

- **Asked for:** "the missing stop isn't sized right, maybe it should be labeled as a red or something? missing data? idk? but either way! fix that!"
- **Decided:** keep the ruler's even spacing of fixes; center stop labels on narrow stops, and mark silences of 10 minutes or more (Coverage's gap length) with a red band and a red "No data" label below stop labels in priority.
- **Undo:** `git revert 913fb7a`.

## 2026-11-08: Go To movement names by distance (9645510)

- **Asked for:** "the go to page says flight for something also? when the top little bubble itself says driving??"
- **Decided:** name a movement after the activity covering the most corrected distance; a flight needs a quarter of it.
- **Undo:** `git revert 9645510`.

## 2026-11-08: Go To restyle (b394587)

- **Asked for:** "make the entire go to page better and better themed as well!"
- **Decided:** glass sheet styling, Today/Yesterday day headers with stop counts and distance, colored activity icons (Drive blue, Walk green, Cycle orange, Flight purple), time ranges, durations and a Viewing badge.
- **Undo:** `git revert b394587`.

## 2026-11-08: Trip page without a title (bf2fa64)

- **Asked for:** "does the trip page need to show trip and choose a mode? Also how do you choose other trips and replace the trip mode?"
- **Decided:** remove the title and subtitle, add Edit (Trip Modes) at the end of the mode row and move Trip Settings beside Start Trip. Changing a mode mid-trip stays out: uploads and Health keep the starting mode.
- **Undo:** `git revert bf2fa64`.

## 2026-11-08: live trip stats (a1cdcf6)

- **Asked for:** richer live stats on the Trip page (picked from offered options).
- **Decided:** a 2×2 grid of distance, average speed (pace for walking, running and hiking modes), top speed and climb. Current speed stays in the map's speedometer. Top speed needs speed accuracy within 5 m/s; climb counts rises of 5 m or more with vertical accuracy within 10 m.
- **Undo:** `git revert a1cdcf6` (revert a614812 first).

## 2026-11-08: recent trips (a614812)

- **Asked for:** recent trips on the Trip page (picked from offered options).
- **Decided:** keep up to 20 finished-trip summaries on the device (no coordinates, not in Backup & Sync), list the newest five while idle, and open a trip's start on the Tracker ruler while it is still in local history.
- **Undo:** `git revert a614812`.

## 2026-11-08: silences inside stops (0e5b96e)

- **Asked for:** a properly sized 66-minute stop; earlier the owner floated marking it red as missing data.
- **Decided:** a silence inside a detected stop is not marked as missing data, since a phone that logs only when it moves goes quiet while parked. Silences of ten minutes or more outside stops keep the red No data band.
- **Undo:** `git revert 0e5b96e`.

## 2026-11-08: stop width on the history ruler (b7fae9a)

- **Asked for:** stops sized by time; the owner picked "Weighted by time" from offered options.
- **Decided:** every fix keeps one slot, and each stop or silence outside a stop gets extra width spread across its time: 3 bars close up for 5 minutes plus 3 per doubling, or the width of 150 × √(minutes / 5) fixes when that is smaller, so it shrinks when zoomed out and the coarsest step fits the whole history. Time and day marks sit at their exact time; the scale estimate uses the median nearby interval. A fixed time weighting would either hide stops when zoomed out or turn them into multi-screen walls close up.
- **Undo:** `git revert b7fae9a`.

## 2026-11-08: the history ruler shows time (7f42ede)

- **Asked for:** the scale label jumped from 22 to 3.3 minutes per bar as the needle moved ("So inconsistent!").
- **Decided:** a slot is the median interval between moving fixes, and each step outside a stop is as wide as its duration (never under one slot), so a bar covers the same time wherever the phone moved; the label and menu use the slot. Stops stay compressed blocks, as picked earlier. Long stretches are capped close up at 8 bars plus 3 per doubling, and zoomed out time past 5 minutes counts as 5 minutes × √(minutes / 5). The map's ruler fit window counts ruler bars. Sparse movement such as walking now takes more room than before.
- **Undo:** `git revert 7f42ede` (revert the Live flight commit after it first).

## 2026-11-08: even ruler ticks and compact stops (f3e6c68)

- **Asked for:** the time ruler looked "terrible": ticks crammed inside a Home stop that filled the ruler.
- **Decided:** ticks count slots back from Live, so they are even while moving and absent inside stops; close up a stop keeps 4 bars for 5 minutes plus 1.5 per doubling (about 15 for twelve hours). Only stops and silences of 5 minutes or more are stretches; shorter moving pauses keep their real time even at the finest scale.
- **Undo:** `git revert f3e6c68`.

## 2026-11-08: a time ruler (936aba7)

- **Asked for:** rethink the ruler after uneven ticks and overlapping stops; the owner picked "same time everywhere" and a minute per bar at Live from rendered comparisons.
- **Decided:** a bar is a fixed time from a clock-friendly ladder (1 s to 2 weeks), ticks on local clock multiples, taller on boundaries at least four steps long; stops tinted exactly, with back-to-back stops at the same Wi-Fi Place, or touching unnamed ones, merged when under 10 minutes apart. Live sits one bar past the newest fix. The map's scale zoom starts past a minute per bar so the live map is unchanged. This replaces the time-weighted and folded-stop rulers logged earlier today.
- **Undo:** `git revert 936aba7`.

## 2026-11-08: back to evenly spaced points (dce73ed)

- **Asked for:** the time ruler "overall works worse", "terrible to use"; scrolling was comfortable a day or two earlier, before the spacing changes.
- **Decided:** restore the ruler from before today's spacing changes, with a bar of evenly spaced fixes and every point at Live. Keep the Live button's glide (easing through positions), silences inside a stop staying unmarked, and a visit split by a stray fix shown as one stop. A ruler of equal time is mostly empty parking on this phone, which logs about once a second while moving and every few minutes, or not at all, while parked.
- **Undo:** `git revert dce73ed` (revert c64b3ec and 3b13ead first).

## 2026-11-08: a steady scale label (c64b3ec)

- **Asked for:** earlier today the scale capsule jumped from 22 to 3.3 minutes per bar as the needle moved ("So inconsistent!").
- **Decided:** the capsule, bubble and menu use the history's average time per point (oldest to newest fix) times the points per bar, marked ≈, so they change only with the scale. A bar on a drive is shorter than that and one across a stop longer. The median interval was rejected because the phone logs about once a second while moving, so it would undersell coarse scales.
- **Undo:** `git revert c64b3ec`.

## 2026-11-08: long stops clear the needle (3b13ead)

- **Asked for:** a 66-minute stop was "so small the cursor bar hides it".
- **Decided:** a stop's tint widens with its length, from its own width at 5 minutes to 22 points from an hour, but only halfway toward a neighboring stop, and a stop squeezed under a point by its neighbors is not drawn. A fixed 22-point minimum turned the whole-history view into a green stripe of short stops. Scrolling and snapping use the stop's real position.
- **Undo:** `git revert 3b13ead`.

## 2026-11-08: ruler glass no longer reacts to touches (5fa7c8e)

- **Asked for:** menu items that respond ("can't press the buttons").
- **Decided:** the history ruler's glass panel is plain glass rather than interactive glass. Interactive glass tracks touches across the window and took presses of a third of a second or more from scale menu items drawn over it. The panel no longer flexes under a finger.
- **Undo:** `git revert 5fa7c8e`.

## 2026-11-08: trips rebuilt from history (463262e)

- **Asked for:** CarPlay trips in Recent Trips.
- **Decided:** list every retained trip from the trip tags on its history fixes when no summary was saved, with distance across its fixes and top speed and climb from the trip stats accumulator. Saved summaries win. The cause of the missing summaries is still unknown.
- **Undo:** `git revert 463262e`.

## 2026-11-08: See All trips (4ecb458)

- **Asked for:** a See All that opens a modal.
- **Decided:** See All appears beside Recent Trips only when more trips exist than the five shown, and opens a sheet grouped by day in Go To's style.
- **Undo:** `git revert 4ecb458`.

## 2026-11-08: scale button during ruler motion (867e40c)

- **Asked for:** the Every point button responding ("only opens when the ruler isn't being scrolled").
- **Decided:** the scale capsule stays enabled while the ruler moves. A menu choice during a drag or coast stops the ruler where it is, then eases the scale with the needle anchored.
- **Undo:** `git revert 867e40c`.

## 2026-11-08: opened trips in red (ca9b14f)

- **Asked for:** clicking a trip to replace its track with red; the owner chose red until returning to Live, fitting the whole trip, and a red band on the ruler.
- **Decided:** a 4-point red foreground layer above the blue, the replay overview fitted to the trip's fixes, and a 30% red band on the ruler beneath stop tints.
- **Undo:** `git revert ca9b14f`.

## 2026-11-09: App Store switch (3a54737, 790629a)

- **Asked for:** drop silent audio from App Store builds; the app will also ship through any other channel that helps it.
- **Decided:** `WHEREWOLF_APP_STORE=YES` (default NO) compiles out the TestFlight diagnostics collector and silent audio and drops the audio background mode through the preprocessed Info.plist; every other build keeps them. The unused fetch background mode is gone from all builds.
- **Undo:** `git revert 3a54737 790629a`.

## 2026-11-09: animated trip opening (767a8cd)

- **Asked for:** pressing a trip should slide the tab over, zoom the map out and in, then slowly highlight the trip in red.
- **Decided:** the drawer's controls and tab highlight slide over to Tracker (0.38 s), the map flies along `MapFlight` to fit the trip, and the red draws from the trip's start to its end over 1.2 s after the camera arrives. Reduce Motion fades and jumps.
- **Undo:** `git revert 767a8cd`.

## 2026-11-09: Settings reorganization (01919c1)

- **Asked for:** the owner approved the proposed Settings tree.
- **Decided:** the root reads Setup Guide; Tracking; Destination and Permissions; Recording (Tracking & Accuracy, Trips, Wi-Fi Places); Sending; Background (Live Activities, Background Reliability); Your Data (History & Replay, Apple Health, Backup & Sync); Notifications; Troubleshooting (Coverage, Location Log, Diagnostics); Support. Destination is the server screen plus Save Locations To and File Organization, and its row shows Server, iCloud Drive or Not Set. Permissions gathers the location, Precise Location, Motion & Fitness, notification and Health request rows that were on the root, in Motion & Adaptive and in Coverage. Tracking & Accuracy merges Tracking & Precision, Stationary Pause and Point Selection & Quality, with an Advanced page for the engine, motion assist and adaptive tracking; Background's duplicate Active Engine is gone. Trips shows Max Saved-Point Error and Resume After Moving read-only (Tracking & Accuracy now shows Resume After Moving while either pauses automatically, so it stays editable) and links to Live Activities for its activity switch. Retry Background Helpers restarts more than activities, so it stays in Background Reliability as Restart Background Features. Integrations & Exports and Coverage's keep-alive section are gone; Location Updates & Recovery became Location Log, its log rows renamed to match. Rows, onboarding and help now share the approved names, plus Island Appearance and Save When Any Limit Is Met. Onboarding's server sheet keeps its GeoJSON/OwnTracks Format picker, a server format choice rather than Logging Mode. Long footers moved into regrouped help topics, including new Destination, Saved Points, Live Activities, History & Replay and Apple Health topics. No defaults key, binding or side effect changed.
- **Undo:** `git revert 01919c1` and the docs commit after it.

## 2026-11-09: sorted options and bulleted help (8b412be, 5ed3b97)

- **Asked for:** presets "sorted from like most accurate/least battery efficient to inverse", the same for other lists rather than "randomly dumped", and info buttons that are "less verbose" with "lists", "bullet points" and "the efficacies and inefficiencies".
- **Decided:** option lists follow an axis instead of tag order. Presets run Driving, High Resolution, Walking / Running, Everyday Detailed, Balanced, Low Power in Settings (after Custom), onboarding and the watch; Requested Accuracy Navigation, Best, Custom; Update Mode Standard, Both, Significant, Off; Activity Type Other, then Fitness, Automotive, Navigation, Boat, Airborne, also in Shortcuts; Logging Mode All Data, OwnTracks, Only Latest; onboarding's Island choices match Settings' Status, Minimal, Blank, then Off; Wi-Fi Place colors follow the spectrum. Lists that already ascend (durations, counts, replay rates, ruler scale) or have no axis (map styles, destinations, user-ordered trip modes, workouts grouped by activity, place icons) stay. Each help entry is now a one-line summary with green advantages, orange drawbacks and gray notes, one entry per option in picker order, about a third shorter, with caveats compressed rather than dropped. Long footers on workout import, backup, connection test and trip modes are shorter too. Tags, stored values and defaults are unchanged.
- **Undo:** `git revert 5ed3b97 8b412be` and the docs commit after them.

## 2026-11-09: Everyday Detailed drops fixes worse than ±50 m (fe35b83)

- **Asked for:** "should we defaults set a max saved-point error?" after a ±200 m point appeared among ±5 m ones.
- **Decided:** the Everyday Detailed preset, the new-install default, sets Max Saved-Point Error to 50 m; in the owner's last week that drops 1.3% of points (all of the ±200 m to ±5 km strays) and keeps every Wi-Fi Place point (777ba65). The five original presets keep the filter off. A phone on Everyday Detailed with the filter off shows Custom until it is set to 50 m or the preset is chosen again.
- **Undo:** `git revert fe35b83`.

## Deferred for the owner

- **Watch complication for Today:** it needs a new watch widget extension and bundle identifier, which is an Apple developer account change.
- **TestFlight upload:** it waits for the owner's own approval.
