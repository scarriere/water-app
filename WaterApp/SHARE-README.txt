Water for macOS 14 or newer (Apple Silicon and Intel)

1. Unzip this archive and drag Water.app into Applications.
2. Open Water.app. Look for the droplet in the menu bar (there is no Dock icon).
3. If macOS says it cannot verify the developer, only if you trust the sender:
   try opening once, then go to System Settings > Privacy & Security > Open Anyway.
   Follow Apple's instructions: https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac
4. The app stores your daily totals only on your own Mac in
   ~/.local/state/water-cli/YYYY-MM-DD.json (or $XDG_STATE_HOME/water-cli/).
   No personal tracking data is included in this archive.
5. Google Health export is optional and requires an authorized Google Health
   project, an OAuth client ID embedded at build time, and your consent via
   the Connect button. Only timestamped water drinks are uploaded.

This build is ad-hoc signed, not notarized by Apple. System notification
permission may not register on another Mac. The optional Full-screen reminders
setting uses an in-app overlay and works without notification permission while
Water is running. For seamless distribution and reliable macOS notifications,
the sender needs to sign with a Developer ID certificate and notarize the app.
