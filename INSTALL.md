# Installing VAKT

Two paths: run the release build, or build it yourself. Building it yourself is
the honest recommendation for something that watches your camera — but the
release build is here because "compile it first" is not always practical.

Requires macOS 14 or later.

---

## Read this first: the app is not notarised

VAKT is signed **ad-hoc** ("Sign to Run Locally"), not with an Apple Developer ID,
and it is not notarised. Two consequences you should understand rather than
click past:

1. **macOS will try to block it.** That is Gatekeeper working correctly, not a
   bug. The steps below tell macOS to trust this specific app. Only do that for
   software you actually want to trust.
2. **It cannot run sandboxed.** The App Sandbox blocks both of VAKT's screen-lock
   paths, so it would detect an intruder and then be unable to act. The app runs
   with the sandbox off, which means it has the same access to your account as
   any other program you run. Ad-hoc signing also means macOS disables Hardened
   Runtime for it.

What VAKT does *not* do, and what you can verify in the source: no frames or
images are written to disk, there is no network code in the app at all, and the
enrolled face template is a set of float vectors in the Keychain marked
`WhenUnlockedThisDeviceOnly` and non-syncing.

---

## Option A — run the release build

1. Download `VAKT.zip` from the
   [latest release](https://github.com/jacksonmafra-umain/vakt/releases/latest).
2. Unzip it and move `VAKT.app` to `/Applications`.
3. Remove the download quarantine flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/VAKT.app
   ```

4. Open it: `open /Applications/VAKT.app`.

An eye icon appears in the menu bar. There is no Dock icon and no main window —
VAKT is a menu-bar app. On first launch it opens the enrolment window because
there is no face on file yet.

### If macOS blocks it anyway

Symptoms and fixes, in the order to try them:

**"VAKT.app is damaged and can't be opened" or "cannot be opened because the
developer cannot be verified"**

The quarantine flag is still set, or the app was moved after you cleared it. Run
the `xattr` command above again, then try opening it.

**"Apple could not verify VAKT is free of malware"** (macOS 15+ wording)

1. Try to open the app once and let it fail.
2. System Settings → **Privacy & Security** → scroll to the Security section.
3. There is a line about VAKT being blocked with an **Open Anyway** button.
4. Click it, authenticate, then open the app again.

**Right-click to open (older wording, still works)**

Control-click `VAKT.app` in Finder → **Open** → **Open** in the dialog. This
records an exception for that copy of the app.

**Nothing appears at all**

The menu bar may be full — macOS silently hides overflow items on notched
displays. Check with:

```sh
pgrep -lf VAKT.app
```

If the process is running, the icon exists but has nowhere to draw. Quit some
other menu-bar apps, or use a menu-bar manager.

### Permissions VAKT will ask for

- **Camera** — on the first arm or enrolment. Without it VAKT cannot work.
  If you refused by accident: System Settings → Privacy & Security → Camera →
  enable VAKT.
- **Touch ID or your login password** — every time you arm, disarm, enrol,
  change the rules or quit. That is the point: the guard's own controls are
  behind the same authentication as your Mac.

The camera LED will light whenever VAKT samples. It is wired to the sensor in
hardware and no software can suppress it. Treat the blinking LED as an honest
"armed" indicator.

---

## Option B — build it yourself

```sh
brew install xcodegen                 # once
git clone https://github.com/jacksonmafra-umain/vakt.git
cd vakt
xcodegen generate                     # writes VAKT.xcodeproj
xcodebuild -project VAKT.xcodeproj -scheme VAKT -configuration Release -derivedDataPath build build
open build/Build/Products/Release/VAKT.app
```

No Gatekeeper prompt: an app you built locally was never quarantined.

If you have an Apple Developer ID, put your team in `Local.xcconfig`:

```
DEVELOPMENT_TEAM = ABCDE12345
```

That gives the app a stable code identity, which matters for more than
formality — with ad-hoc signing the identity changes on every rebuild, so macOS
re-asks for camera access and Keychain access to your enrolled template each
time.

Edit `project.yml` rather than project settings in Xcode: the `.xcodeproj` is
generated and gitignored.

---

## Recommended after installing

**Require the password immediately after the screen locks.** Otherwise VAKT locks
and an intruder wakes it straight back up:

```sh
sysadminctl -screenLock immediate -password -
```

**Survive a force-quit.** Load the LaunchAgent so the app comes back if it is
killed:

```sh
cp com.jacksonmafra.vakt.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.jacksonmafra.vakt.plist
```

The plist points at `/Applications/VAKT.app`; edit it if you keep the app
elsewhere. To undo:

```sh
launchctl bootout gui/$(id -u)/com.jacksonmafra.vakt
rm ~/Library/LaunchAgents/com.jacksonmafra.vakt.plist
```

---

## Uninstalling

```sh
launchctl bootout gui/$(id -u)/com.jacksonmafra.vakt 2>/dev/null
rm -f ~/Library/LaunchAgents/com.jacksonmafra.vakt.plist
rm -rf /Applications/VAKT.app
rm -rf ~/Library/Application\ Support/VAKT          # the decision log
defaults delete com.jacksonmafra.vakt               # your policy settings
```

Use **Forget my face…** in the menu before deleting the app — that is what
removes the template from the Keychain. If the app is already gone:

```sh
security delete-generic-password -s com.jacksonmafra.vakt -a owner.template.v1
```

---

## Tuning it

Everything that decides a lock is a threshold, and thresholds are personal to
your camera and your lighting. Arm VAKT, open the menu, and watch `Liveness`,
`Match`, `Depth` and `Scene coupling` while you work. Every decision is recorded
with the scores that produced it in:

```
~/Library/Application Support/VAKT/events.jsonl
```

That file is how you tune without guessing. The knobs and their symptoms are
tabulated in the README under Calibration.
