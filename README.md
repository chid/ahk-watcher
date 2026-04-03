# Screen Image Watchers With Pushover

This folder contains two Windows-oriented watchers:

- an AutoHotkey v2 version in `watch_image.ahk`
- a Python + OpenCV version in `watch_image.py`

Both versions:

- look for an image on screen
- retry across multiple configured scales
- confirm the match across consecutive scans to reduce false positives
- send a Pushover notification when confirmed
- optionally click the match center

## Files

- `watch_image.ahk`: the watcher
- `watch_image.ini.example`: starter config
- `watch_image.py`: Python/OpenCV watcher
- `watch_image_python.ini.example`: starter config for Python
- `requirements-python.txt`: Python dependencies
- `watch_image.log`: created at runtime if logging is enabled
- `watch_image_python.log`: created by the Python watcher if logging is enabled

## AutoHotkey Setup

1. Install AutoHotkey v2 on Windows.
2. Copy `watch_image.ini.example` to `watch_image.ini`.
3. Put your reference image next to the script or point `ImagePath` at an absolute path.
4. Fill in your Pushover `AppToken` and `UserKey`.
5. Double-click `watch_image.ahk`.

## Python Setup

1. Install Python 3.10+ on Windows.
2. Install dependencies with `pip install -r requirements-python.txt`.
3. Copy `watch_image_python.ini.example` to `watch_image_python.ini`.
4. Put your reference image next to the script or point `ImagePath` at an absolute path.
5. Fill in your Pushover `AppToken` and `UserKey`.
6. Run `python watch_image.py`.

## Important Config

- `Scales`: comma-separated list of sizes to try relative to the original image.
- `SearchRegion`: use `full` or `x,y,w,h` to limit search cost.
- `RequireConfirmations`: consecutive hits required before notifying or clicking.
- `ClickOnMatch`: `1` enables automatic clicking after a confirmed match.
- `CooldownMs`: suppresses repeat alerts while the image stays visible.
- `MatchThreshold`: Python-only similarity threshold from `0` to `1`.
- `Variation`: AutoHotkey-only color tolerance.
- `PauseToggle` / `ManualScan`: optional hotkeys for the AutoHotkey watcher.

## Notes

- The script only alerts once while the image remains visible. It resets after the image disappears for the configured number of missed scans.
- Tray menu actions are available for pause, resume, manual scan, config reload, and exit in the AutoHotkey version.
- If you want conservative behavior, keep `ClickOnMatch=0` until the matching settings are dialed in.
