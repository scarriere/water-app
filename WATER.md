# Water CLI

Run `./water.py` for two side-by-side bottles. Press `a` to add a 355 ml glass, `r` to remove the last one, or `q` to quit. For scripts, use `--add`, `--remove`, or `--reset`; `--no-animation` skips pouring. Your daily water total and drink timestamps live under `~/.local/state/water-cli/YYYY-MM-DD.json` (or `$XDG_STATE_HOME/water-cli/`).

Each new drink has a stable ID shared with the macOS app. The CLI itself does not contact Google; when the macOS app is connected to Google Health and running, it discovers and exports new CLI drinks and removals.

The second bottle reads **today's reported Pi output tokens across all saved sessions** in `~/.pi/agent/sessions/`. It counts assistant, tool-reported and summary output usage, **excluding input and cached tokens**. It updates every 5 seconds while the CLI is open and scales its graduations as the total grows. Only numeric usage is displayed; session messages are not displayed or copied into the water JSON. Set `PI_CODING_AGENT_SESSION_DIR` if Pi stores sessions elsewhere.

**Conversion chosen for this tracker: 0.7 ml per 1,000 tokens.** The Pi bottle's volume is an *illustrative water equivalent*, **not** a measured environmental footprint. The numeric token count is Pi's reported output usage; the water amount is just that count multiplied by the chosen ratio. The blue bottle is your real water intake; the purple bottle is the estimate. If Pi has no saved sessions, its count is zero.
