# Changelog

All notable changes to VAKT. Newest first.

## 0.2.4 — 2026-08-27

### Fixed

- `install.sh --launch-agent` started VAKT twice. `launchctl bootstrap` launches
  the app itself, and the script then ran `open` as well: two eye icons in the menu
  bar, two watchers, the camera claimed twice. It now skips the launch when the app
  is already running.

## 0.2.3 — 2026-08-27

### Fixed

- **Settings never came to the front.** Two causes. The fronting helper was only
  applied to the enrolment and about windows, so Settings had nothing bringing it
  forward at all. And the helper it now shares only fronted a window when the view
  was first created, which is wrong for a window SwiftUI reuses — it would have
  come forward once and never again.
- **Fronting no longer depends on activation.** `NSApp.activate(ignoringOtherApps:)`
  is deprecated and the system is free to refuse; measured on macOS 26, the window
  appeared on screen while the frontmost app never changed, leaving VAKT's window
  behind whatever the user was reading. Windows are now raised to
  `NSWindow.Level.floating` and dropped back to `.normal` as soon as they really
  become key, so they do not hover over everything afterwards.
- Settings is fronted without being re-centred, since it is a window you may have
  placed where you want it.

## 0.2.2 — 2026-08-27

Fixes the worst failure this app had: locking the screen of the person it had just
recognised.

### Fixed

- **False `spoofSuspected` locks on a still, reading owner.** Observed twice in 18
  seconds on a real session, with the identity match at 0.885 and 0.904 and the
  liveness score at 0.247 and 0.222 against a 0.25 floor. Without a detected
  blink the score cannot exceed `0.55 × motion + 0.10 × jitter`, so someone
  reading quietly lands exactly in spoof range. Three independent changes, each
  enough on its own to have prevented it:
  - A spoof verdict is vetoed when head depth is confirmed. Parallax proves there
    is a volume in front of the camera, so "it never moved like a living one" is
    just wrong.
  - An authenticated unlock now suppresses all three spoof-shaped locks — still
    face, flat geometry, held device — for `Policy.trustAfterUnlock` (90s,
    adjustable in Settings). Touch ID is a far stronger presence signal than
    anything the camera infers. Absence and strangers are unaffected.
  - The sample window for a spoof verdict must now span 10 seconds, not 4.

## 0.2.1 — 2026-08-27

Getting VAKT installed and actually running without having to remember it.

### Added

- **Start watching as soon as VAKT launches** (`Policy.armAtLaunch`, off by
  default, in Settings). The LaunchAgent already started the app at login, but the
  app came up disarmed and waited for a decision nobody makes — so "starts at
  login" protected nothing. Arming is the one gated action that does not weaken
  anything, since it turns protection on against a template only you enrolled, so
  the automatic path does not authenticate. Disarming still does.

- `install.sh`, shipped inside the release zip. It stops any running copy — first
  unloading the LaunchAgent, which would otherwise relaunch VAKT in the middle of
  the copy — installs to `/Applications`, clears the `com.apple.quarantine` flag
  that makes macOS refuse to open a downloaded un-notarised app, verifies the
  bundle with `codesign`, and launches it. Every command is printed before it
  runs; `--dry-run` prints them and changes nothing. Flags: `--launch-agent`,
  `--dest`, `--no-open`, `--dry-run`.

  It clears quarantine for that one bundle and nothing else. No
  `spctl --master-disable`, no system-wide Gatekeeper change.

- The release zip now also carries `INSTALL.md` and the LaunchAgent plist, so
  everything needed is in one download.

### Fixed

- `install.sh` died with `SUDO[@]: unbound variable` under `/bin/bash`, which on
  macOS is still bash 3.2 — expanding an empty array trips `set -u` there. Sudo is
  a function now, not an array prefix.
- The writability check ran before the destination was created, so it asked for
  administrator rights when it did not need them. It now tests the closest
  existing ancestor.

## 0.2.0 — 2026-08-27

Anti-replay work: the first release that tries to answer "what if it is a video
of me, not a photo of me". Plus the enrolment screen, which the first release
simply did not have.

### Added

- **Enrolment window** with a live camera preview, `n of 18` progress, and the
  reason each frame was rejected — too far, too dark, not yet proven live, or a
  near-duplicate pose. A capture that fails silently is indistinguishable from a
  broken camera.
- **Planar replay detection** (issue #2). A video of a face deforms and blinks
  like a face does, so the existing liveness score calls it live. What a display
  cannot fake is depth: every landmark on a flat panel moves under one
  homography. VAKT fits a normalised-DLT homography across rotated frame pairs
  and measures the reprojection error it cannot absorb, per radian of rotation.
  A plane scores zero at every angle; a head scores well above the floor.
  New lock reason: `screenReplay`.
- **Background rigidity** (issue #3). A phone or print held in the hand carries
  its background along with the face. VAKT registers patches outside the face box
  between frames and compares their translation with the face's own. Sustained
  agreement while the face is clearly moving means one rigid object.
  New lock reason: `heldDevice`. Vetoed when head depth is already proven, so a
  nudged desk — which moves face and room together — does not get blamed.
- **Camera pinning** (issue #1). A deepfake is more likely to arrive through a
  virtual camera than through a phone held to the lens. External, Continuity and
  virtual cameras are refused, and the sensor `uniqueID` is recorded at enrolment
  so VAKT will not watch through a different one.
- **About window** with version, credits and the privacy claims.
- **Authorisation status** in Settings: whether this Mac will confirm changes
  with Touch ID or the login password.
- `Depth` and `Scene coupling` readings in the menu, alongside liveness and match.
- XcodeGen project generation (`project.yml`), so the Xcode project is disposable
  rather than a checked-in artefact.

### Changed

- Capture runs at 720p instead of 640×480. Vision rated the smaller crop's
  capture quality low, which starved enrolment and made the identity match skip
  frames.
- One shared capture-quality floor (`FaceQuality.minimum`, 0.30) for enrolment and
  matching. They were 0.45 and 0.35, so enrolment demanded frames better than the
  watcher would ever accept — and stalled at zero captures on an ordinary webcam.
- A spoof verdict now requires the sample window to span at least 4 seconds. At
  30fps the old 24-pair minimum could be met in under a second, which was enough
  to call someone a photograph mid-blink.
- Enrolment no longer arms VAKT on completion. Arming straight out of enrolment
  locked the screen seconds later. Arming is a decision, not a side effect.
- Authentication has three outcomes instead of two: authorised, refused, and
  unavailable. On a Mac where no authentication is possible — no login password —
  weakening protection is refused with the reason shown, while disarming,
  forgetting the face and quitting still work. Previously every control became a
  silent no-op, and an armed VAKT could not be stopped from its own menu while
  the LaunchAgent relaunched it.
- Menu redesigned as flat rows with icons and shortcut hints.

### Fixed

- The enrolment preview was black: `AVCaptureVideoPreviewLayer` was added as a
  sublayer and never resized, because `updateNSView` runs on SwiftUI state
  changes rather than on AppKit layout.
- Windows opened off-screen or behind the frontmost app, and the Touch ID sheet
  appeared behind the user's editor. An accessory app has nothing to bring its
  windows forward for it, and `openWindow` returns before the window exists.
- The camera failing while armed left VAKT sitting in `searching` forever. It now
  disarms and says why.

## 0.1.0

First version. Menu-bar watcher, non-rigid deformation liveness against printed
photos, Keychain-backed face template, screen lock via `SACLockScreenImmediate`
with a `CGSession` fallback, power assertion to keep background work running, and
an append-only JSONL decision log.
