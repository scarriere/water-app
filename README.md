# Water

A macOS menu-bar water tracker and companion Python CLI. Both use the same daily JSON files in `~/.local/state/water-cli/` (or `$XDG_STATE_HOME/water-cli/`). The macOS app can optionally export timestamped water drinks to an authorized Google Health API project via OAuth.

- [macOS app: installation, Google Health setup, data and tests](WaterApp/README.md)
- [CLI usage](WATER.md)

From this directory:

```sh
python3 -m unittest test_water.py
xcodebuild -project WaterApp/WaterApp.xcodeproj -scheme Water \
  -destination 'platform=macOS' -derivedDataPath /tmp/water-derived test
```

Google Health OAuth requires an existing onboarded Cloud project, a desktop client ID, and consent from the Google account holder. The app works without a Google connection. No OAuth credentials, health records, or build archives belong in this repository.
