# AutoHotkey Image Watcher With Pushover

This folder contains an AutoHotkey v2 watcher that:

- looks for an image on screen with color variation tolerance
- retries across multiple configured scales
- confirms the match across consecutive scans to reduce false positives
- sends a Pushover notification when confirmed
- optionally clicks the match center

## Files

- `watch_image.ahk`: the watcher
- `watch_image.ini.example`: starter config
- `watch_image.log`: created at runtime if logging is enabled

## Setup

1. Install AutoHotkey v2 on Windows.
2. Copy `watch_image.ini.example` to `watch_image.ini`.
3. Put your reference image next to the script or point `ImagePath` at an absolute path.
4. Fill in your Pushover `AppToken` and `UserKey`.
5. Double-click `watch_image.ahk`.

## Important Config

- `Variation`: higher values tolerate more color drift but raise false-positive risk.
- `Scales`: comma-separated list of sizes to try relative to the original image.
- `SearchRegion`: use `full` or `x,y,w,h` to limit search cost.
- `RequireConfirmations`: consecutive hits required before notifying or clicking.
- `ClickOnMatch`: `1` enables automatic clicking after a confirmed match.
- `PauseToggle` / `ManualScan`: optional hotkeys for control.

## Notes

- The script only alerts once while the image remains visible. It resets after the image disappears for the configured number of missed scans.
- Tray menu actions are available for pause, resume, manual scan, config reload, and exit.
- If you want conservative behavior, keep `ClickOnMatch=0` until the matching settings are dialed in.
# ahk-watcher
