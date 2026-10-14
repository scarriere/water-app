# Water for macOS

A native SwiftUI menu-bar app beside the existing `water.py` CLI. Requires macOS 14 or newer and Xcode.

## Run

From the `water-app` directory, quit any running Water app and install a signed copy at a stable path:

```sh
./WaterApp/install-local.sh
```

The script builds Water, signs the **whole app bundle** (including its Info.plist), registers it with macOS, and opens `~/Applications/Water.app`. Xcode's unsigned temporary build can run, but it may not appear in macOS Notification Settings. If you have an Apple Development signing certificate, use `WATER_CODESIGN_IDENTITY="Apple Development: …" ./WaterApp/install-local.sh` for more reliable notification registration. An ad-hoc signature is used otherwise. Do not run the old `/tmp/.../Water.app` at the same time.

Click the **droplet icon in the macOS menu bar** to open the tracker. Click **Add glass (+355 ml)** to save immediately and animate blue water pouring into the bottle. Click **Remove glass (-355 ml)** to undo the latest logged glass (or an untimed legacy glass); the bottle level falls and the deleted glass no longer counts toward hourly reminders. The wide bottle shows marks every 500 ml, the 2.7 L goal, and up to 3 L of water. Totals above 3 L are still saved and shown numerically. The app refreshes when the popover opens and every 30 seconds while it is open, including after midnight. Use **Quit Water** at the bottom of the popover to exit. This is a menu-bar-only app: it does not show a Dock icon or open a separate window.

Choose the delivery style in the popover. **Full-screen reminders (instead of banners)** is opt-in and uses a Water-owned overlay on the active display, like MeetingBar's full-screen reminders. It works without macOS notification permission; click **Preview full-screen reminder** to try it. Dismiss it with the button or Escape; it also closes automatically after 45 seconds. When full-screen mode is off, allow macOS notification permission for system banners: use **Enable notifications** to retry, **Send test notification** to check delivery, and **Notification Settings** to open the macOS controls. The app cannot make a *system* notification full-screen—only its own window. While the app runs, it checks **once per hour** how much was logged in the preceding 60 minutes. If that is **less than 250 ml**, it sends a macOS reminder. The first check is after a full hour; missed checks while the Mac sleeps are not queued. Reminders also run overnight; macOS Focus/Do Not Disturb and notification settings control delivery. If the ad-hoc-signed app still cannot register, an Apple Development signing identity is required to test notifications reliably.

## Google Health export (optional)

Google Health API access is required: Google currently does **not** onboard new projects. Create a **Desktop** OAuth client in an authorized Google Cloud project, enable the Google Health API, configure the consent screen (and its test users / production verification), and add both `https://www.googleapis.com/auth/googlehealth.nutrition.writeonly` and `https://www.googleapis.com/auth/googlehealth.nutrition.readonly` to Data Access. Give Water's OAuth client ID to the build (this is a public identifier, not a secret):

```sh
GOOGLE_HEALTH_CLIENT_ID='your-desktop-client-id.apps.googleusercontent.com' ./WaterApp/install-local.sh
```

Use the same variable with `./WaterApp/package.sh` when sharing a build. Without it, the local tracker still works, but Connect displays a configuration error. Each recipient must be authorized to use your Google Health project. The browser sign-in uses a PKCE-protected localhost callback. Google also requires the Desktop OAuth client's `client_secret` for its token endpoint: enter it in Water's **Desktop OAuth client secret** field, then click **Save & Connect**. Water stores it in macOS Keychain and uses it for code exchange and token refresh. It is never included in the source, build settings, app bundle, or water JSON. **Do not paste it in chat or commit it to Git.** Disconnect removes both OAuth tokens and the locally stored client secret.

Click **Connect** in the menu-bar app to start exporting new timestamped drinks. Existing connections need **Grant read access** once to approve the new nutrition read scope. **Drinks on Google → Refresh list** performs only read requests and shows remote hydration records matching Water's local exports. A known server ID is **Confirmed**; a record matching an uncertain Water drink only by time and volume is a **Possible match**, not proof of origin and never an automatic reason to retry or delete it. Other apps' drinks are not shown. The read list is kept in memory and capped at 1,000 records; if Google refuses read access, the app displays its HTTP status. Local JSON is authoritative: the app also picks up CLI edits at launch and every five minutes while running. **Sync now** checks immediately; pending Google operations are checked on later syncs. **Export earlier timed drinks…** opts in to backfilling recorded history, which might duplicate existing Google water logs. Untimed legacy totals are never exported. Removing or resetting an exported drink queues deletion from Google. **Disconnect** removes local credentials but deliberately does not delete Google data. No syncing takes place while the macOS app is quit.

The per-account `google-health-<subject>.json` ledger alongside daily files stores Google's server-assigned IDs and in-flight operations. **Keep this file** along with the daily files: deleting it can cause duplicate exports after reconnecting. Ambiguous uploads are never retried automatically; if Water shows a review warning, inspect Google Health for duplicates before using **Review and retry…**. Definite Google HTTP 400/401/403/404/405 upload rejections pause further exports and show their status code; fix access or configuration before pressing **Retry rejected uploads**. Unknown outcomes also pause after the first failure and retain a safe diagnostic for the next launch. Previously uncertain entries remain uncertain after upgrading, since their original response cannot be recovered. App and CLI use a common day-file lock to avoid overwriting simultaneous updates. Google Health only sees actual logged water, not the CLI's illustrative Pi token estimate.

## Data

The app and CLI use the same daily JSON files:

```
~/.local/state/water-cli/YYYY-MM-DD.json
{"date":"YYYY-MM-DD","ml":355,"drinks":[{"at":"2026-10-01T12:00:00Z","ml":355,"id":"550e8400-e29b-41d4-a716-446655440000"}]}
```

If `XDG_STATE_HOME` is set, the files are under `$XDG_STATE_HOME/water-cli/` instead. The app and updated CLI both record a timestamp for each added glass. The CLI can undo one glass with `r` or `./water.py --remove`; it subtracts 355 ml and removes that glass's timestamp so reminders stay accurate. The CLI's `--reset` clears the day's drink history. Older `{date, ml}` files still load, but their untimed water cannot be assigned to a particular hour. Saving uses an atomic replacement. The app re-reads today's file before each addition so it sees drinks added by the CLI. This is a local, non-sandboxed Xcode build; distributing through the Mac App Store would require a sandbox-compatible storage/migration strategy. The Python CLI is not bundled into the app.

## Share with another Mac

Run `./WaterApp/package.sh` from the `water-app` directory. It builds a Release app for both Apple Silicon and Intel Macs, signs and verifies the whole bundle, and writes a ZIP under `WaterApp/dist/` with `READ-ME-FIRST.txt`. The ZIP contains no daily water data. Your colleague needs macOS 14 or newer.

**Signing limitation:** This machine has no Developer ID certificate, so the default archive is **ad-hoc signed and not notarized**. On the recipient's Mac, Gatekeeper may require **System Settings → Privacy & Security → Open Anyway** after an initial launch attempt. Only override the warning if the recipient trusts the sender. System notifications may not register with an ad-hoc build; the app's opt-in full-screen overlay works independently while it runs. For frictionless distribution, sign with a Developer ID identity and notarize the app; setting `WATER_CODESIGN_IDENTITY` when packaging signs with that identity, but does **not** notarize it.

## Tests

```sh
xcodebuild -project WaterApp/WaterApp.xcodeproj -scheme Water \
  -destination 'platform=macOS' -derivedDataPath /tmp/water-derived test
python3 -m unittest test_water.py
```
