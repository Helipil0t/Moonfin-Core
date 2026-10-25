# [UI] DVR Schedule cancellation uses the programme ID; date groups use UTC instead of local time

## Moonfin version

2.7.0, build 30000154, hosted web client supplied by Moonbase 2.4.0.0.  The same affected code paths are present in `main` at `0865e5cf`.

## Platform and server

Web, using mouse/keyboard.  Jellyfin Server 12.3.0.  Client timezone: America/Toronto (UTC−04:00 on the reproduction date).  Exact browser and client OS versions were not captured.  Other client platforms and Emby have not been tested against a live server.

## Where it happens

Live TV → Recordings → Schedule.  The same cancellation pattern also exists in the standalone Schedule screen, and the scheduled-recording mapping is shared with the “Scheduled in Next 24 Hours” row.

## Observed behaviour

Two related problems make a working DVR recording appear incorrectly scheduled and prevent cancelling it from Schedule:

1. An active recording at 8:00 p.m. local time appears under **Tomorrow**.  The Jellyfin timer is `InProgress`, and its recording file is growing normally.
2. Selecting that entry and confirming cancellation displays **Failed to cancel recording**.  Cancelling through the TV guide works.

A second recording created through Jellyfin's own web client appears under **Today** in Moonfin, but cancellation from Moonfin's Schedule still fails.  This separates the cancellation defect from the date-label defect and from the client used to create the timer.

## Steps to reproduce

### Incorrect date grouping

1. Set the client timezone to America/Toronto, or another timezone where an evening local programme falls on the following UTC date.
2. Record an airing that starts during that evening.
3. Open Moonfin's Recordings → Schedule while the recording is running.
4. Compare the heading with the client's local date and Jellyfin's timer status.

Our example was recorded on October 24, 2026:

| Programme | API start time | Toronto local start | Moonfin heading |
| --- | --- | --- | --- |
| Shrek the Third | `2026-10-24T23:00:00Z` | October 24, 7:00 p.m. | Today |
| Real Time With Bill Maher | `2026-10-25T00:00:00Z` | October 24, 8:00 p.m. | Tomorrow |

Both timers were `InProgress` during the observation.  The server clock was synchronized.  Neither recording was actually delayed until tomorrow.

### Failed cancellation

1. Create a recording timer for an EPG programme.  Creating it through either Moonfin or Jellyfin web reproduces the problem.
2. Open Moonfin's Recordings → Schedule.
3. Select the recording and confirm cancellation.
4. Observe **Failed to cancel recording**, with the timer still present.
5. Open the same programme in the TV guide and cancel there; that succeeds.

The relevant response shape has distinct timer and programme IDs:

```json
{
  "Id": "timer-id",
  "Status": "InProgress",
  "StartDate": "2026-10-25T00:00:00Z",
  "ProgramInfo": {
    "Id": "programme-id",
    "TimerId": "timer-id",
    "StartDate": "2026-10-25T00:00:00Z"
  }
}
```

IDs above are illustrative.  Cancelling requires `DELETE /LiveTv/Timers/timer-id`; the Schedule code instead passes `programme-id`.

## Expected behaviour

- Group recordings using the client's local calendar date.
- Cancel using the timer's top-level `Id`, regardless of whether `ProgramInfo` is present.
- Keep the programme/item ID available for artwork and metadata.
- Remove only the cancelled timer from the displayed list and clear its focus after a successful request.

## Source diagnosis

In `ScheduleViewModel._read`, `timer.startDate` is formatted into a date key without `toLocal()`.  `_friendlyDate` then compares those UTC calendar components with the local `DateTime.now()` components.

Both `ScheduleViewModel._read` and `RecordingsViewModel._loadScheduledTimers` construct a `RecordingItem` from `timer.programInfo` when present.  Consequently, `RecordingItem.id` becomes the programme ID.  Both cancellation screens pass `item.id` to `cancelTimer`, and successful removal/focus clearing also compare against that overloaded ID.

The API wrapper already targets the correct `/LiveTv/Timers/{timerId}` endpoint.  The caller supplies the wrong identifier.

Related upstream work in #1960 filters cancelled/completed timers and refreshes recording views.  These identity and timezone paths remain unchanged in the current source checked for this report.

## Proposed fix

[Proposed fix commit](https://github.com/Helipil0t/Moonfin-Core/commit/04a3c1d7d7323ba250dc08b09784540fd7d87154) — six files, including regression tests.  The patch is based on upstream `main` at `0865e5cf`.

The patch makes these changes:

1. Add a separate nullable `RecordingItem.timerId` and a `RecordingItem.fromTimer` factory.  Preserve the programme ID and artwork fields; use the enclosing timer's ID for cancellation even if an embedded `ProgramInfo.TimerId` is absent or stale.
2. Use that factory in both scheduled-recording mappings.
3. Use `item.timerId` in both cancellation screens, and compare timer IDs when removing entries or clearing focus.  A missing timer ID produces the existing error message without sending a programme ID to the timer endpoint.
4. Convert the scheduled start time to local time before grouping.  Compare local calendar components using UTC date-only values, avoiding 23/25-hour day differences at DST boundaries.
5. Add regression coverage for differing IDs, missing `ProgramInfo`, preserved artwork, cancellation failure, duplicate programme IDs, both cancellation screens, local-midnight grouping, and DST transitions.

## Screenshots / recordings

![Active recording incorrectly grouped under Tomorrow](https://raw.githubusercontent.com/Helipil0t/Moonfin-Core/dvr-schedule-fix/docs/bug-reports/dvr-schedule/active-recording-under-tomorrow.png)

![Cancellation fails from Schedule](https://raw.githubusercontent.com/Helipil0t/Moonfin-Core/dvr-schedule-fix/docs/bug-reports/dvr-schedule/failed-to-cancel-recording.png)

![Two recordings from the same local evening under different dates](https://raw.githubusercontent.com/Helipil0t/Moonfin-Core/dvr-schedule-fix/docs/bug-reports/dvr-schedule/today-versus-tomorrow.png)

## Validation

The original behaviour was reproduced against the live Jellyfin server.  The proposed patch passed 55 focused Flutter tests, including 12 new regression cases, using Flutter 3.47.2 and Dart 3.13.2 with `TZ=America/Toronto`.  Static analysis of the four modified production files and two test files found no issues.  Both new cancellation widget tests fail against the original upstream code and pass with the fix.  Patch validation is limited to automated tests and static analysis; the patched app has not yet been tested against a live server.  This report and proposed patch were prepared with AI assistance and reviewed against the affected source paths.
