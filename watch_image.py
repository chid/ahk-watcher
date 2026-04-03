#!/usr/bin/env python3
from __future__ import annotations

import configparser
import ctypes
import logging
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

import cv2
import numpy as np
import pyautogui
import requests


CONFIG_PATH = Path(__file__).with_name("watch_image_python.ini")
LOG_PATH = Path(__file__).with_name("watch_image_python.log")


@dataclass
class Region:
    left: int
    top: int
    width: int
    height: int


@dataclass
class MatchResult:
    x: int
    y: int
    width: int
    height: int
    scale: float
    score: float
    count: int = 1

    @property
    def center(self) -> tuple[int, int]:
        return (self.x + self.width // 2, self.y + self.height // 2)


@dataclass
class Config:
    pushover_app_token: str
    pushover_user_key: str
    pushover_device: str
    notification_title: str
    priority: int
    image_path: Path
    image_label: str
    search_region: Region | None
    scales: list[float]
    scan_interval_ms: int
    match_threshold: float
    use_grayscale: bool
    confirm_radius_px: int
    require_confirmations: int
    clear_after_misses: int
    cooldown_ms: int
    click_on_match: bool
    click_delay_ms: int
    move_mouse_first: bool
    log_to_file: bool


class ImageWatcher:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.candidate: MatchResult | None = None
        self.alerted = False
        self.consecutive_misses = 0
        self.last_alert_time = 0.0

        self.template_color = cv2.imread(str(config.image_path), cv2.IMREAD_COLOR)
        if self.template_color is None:
            raise ValueError(f"Could not load template image: {config.image_path}")

        self.templates = self._build_templates(config.scales)

    def _build_templates(self, scales: Iterable[float]) -> list[tuple[float, np.ndarray]]:
        templates: list[tuple[float, np.ndarray]] = []
        for scale in scales:
            resized = cv2.resize(
                self.template_color,
                dsize=None,
                fx=scale,
                fy=scale,
                interpolation=cv2.INTER_AREA if scale < 1.0 else cv2.INTER_CUBIC,
            )
            if resized.size == 0:
                continue
            if self.config.use_grayscale:
                resized = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
            templates.append((scale, resized))

        if not templates:
            raise ValueError("No valid scaled templates could be created.")
        return templates

    def run_forever(self) -> None:
        logging.info("Python watcher started.")
        while True:
            try:
                self.scan_once()
            except KeyboardInterrupt:
                logging.info("Watcher stopped by user.")
                return
            except Exception as exc:  # noqa: BLE001
                logging.exception("Scan error: %s", exc)
            time.sleep(self.config.scan_interval_ms / 1000.0)

    def scan_once(self) -> None:
        match = self.find_image_on_screen()
        if match is not None:
            self.consecutive_misses = 0

            if self.candidate and self._within_radius(self.candidate, match):
                match.count = self.candidate.count + 1
            else:
                match.count = 1
            self.candidate = match

            can_notify = (not self.alerted) and (
                (time.monotonic() - self.last_alert_time) * 1000 >= self.config.cooldown_ms
            )
            if match.count >= self.config.require_confirmations and can_notify:
                self.handle_confirmed_match(match)
                self.alerted = True
                self.last_alert_time = time.monotonic()
            return

        self.candidate = None
        self.consecutive_misses += 1
        if self.consecutive_misses >= self.config.clear_after_misses:
            if self.alerted:
                logging.info("Match cleared after %s misses.", self.consecutive_misses)
            self.alerted = False

    def find_image_on_screen(self) -> MatchResult | None:
        screenshot = capture_screen(self.config.search_region)
        haystack = np.array(screenshot)
        haystack = cv2.cvtColor(haystack, cv2.COLOR_RGB2BGR)
        if self.config.use_grayscale:
            haystack = cv2.cvtColor(haystack, cv2.COLOR_BGR2GRAY)

        best_match: MatchResult | None = None

        for scale, template in self.templates:
            th, tw = template.shape[:2]
            hh, hw = haystack.shape[:2]
            if th > hh or tw > hw:
                continue

            result = cv2.matchTemplate(haystack, template, cv2.TM_CCOEFF_NORMED)
            _, max_val, _, max_loc = cv2.minMaxLoc(result)
            if max_val < self.config.match_threshold:
                continue

            left_offset = self.config.search_region.left if self.config.search_region else 0
            top_offset = self.config.search_region.top if self.config.search_region else 0
            candidate = MatchResult(
                x=max_loc[0] + left_offset,
                y=max_loc[1] + top_offset,
                width=tw,
                height=th,
                scale=scale,
                score=float(max_val),
            )
            if best_match is None or candidate.score > best_match.score:
                best_match = candidate

        return best_match

    def handle_confirmed_match(self, match: MatchResult) -> None:
        center_x, center_y = match.center
        window_title = get_foreground_window_title()
        process_name = get_foreground_process_name()

        message = "\n".join(
            [
                f"Found {self.config.image_label} at ({center_x}, {center_y})",
                f"Scale: {match.scale:.2f}",
                f"Score: {match.score:.4f}",
                f"Window: {window_title}",
                f"Process: {process_name}",
                f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
            ]
        )

        try:
            send_pushover(self.config, self.config.notification_title, message)
            logging.info("Notification sent for match at (%s, %s).", center_x, center_y)
        except Exception as exc:  # noqa: BLE001
            logging.exception("Notification failed: %s", exc)

        if self.config.click_on_match:
            time.sleep(self.config.click_delay_ms / 1000.0)
            if self.config.move_mouse_first:
                pyautogui.moveTo(center_x, center_y)
            pyautogui.click(center_x, center_y)
            logging.info("Clicked match at (%s, %s).", center_x, center_y)

    def _within_radius(self, left: MatchResult, right: MatchResult) -> bool:
        return (
            abs(left.x - right.x) <= self.config.confirm_radius_px
            and abs(left.y - right.y) <= self.config.confirm_radius_px
        )


def load_config(config_path: Path) -> Config:
    if not config_path.exists():
        raise FileNotFoundError(
            f"Missing config file: {config_path}\n"
            "Copy watch_image_python.ini.example to watch_image_python.ini and fill in your values."
        )

    parser = configparser.ConfigParser()
    parser.read(config_path, encoding="utf-8")

    image_path = resolve_path(config_path, parser.get("Detection", "ImagePath", fallback="sample.png"))
    if not image_path.exists():
        raise FileNotFoundError(f"Configured image file does not exist: {image_path}")

    app_token = parser.get("Pushover", "AppToken", fallback="").strip()
    user_key = parser.get("Pushover", "UserKey", fallback="").strip()
    if not app_token or not user_key:
        raise ValueError("Pushover AppToken and UserKey are required.")

    return Config(
        pushover_app_token=app_token,
        pushover_user_key=user_key,
        pushover_device=parser.get("Pushover", "Device", fallback="").strip(),
        notification_title=parser.get("Pushover", "Title", fallback="Screen match detected").strip(),
        priority=parser.getint("Pushover", "Priority", fallback=0),
        image_path=image_path,
        image_label=parser.get("Detection", "ImageLabel", fallback=image_path.name).strip(),
        search_region=parse_region(parser.get("Detection", "SearchRegion", fallback="full")),
        scales=parse_scales(parser.get("Detection", "Scales", fallback="0.85,0.95,1.00,1.10,1.20")),
        scan_interval_ms=max(100, parser.getint("Detection", "ScanIntervalMs", fallback=500)),
        match_threshold=parse_threshold(parser.get("Detection", "MatchThreshold", fallback="0.92")),
        use_grayscale=parser.getboolean("Detection", "UseGrayscale", fallback=True),
        confirm_radius_px=max(0, parser.getint("Detection", "ConfirmRadiusPx", fallback=20)),
        require_confirmations=max(1, parser.getint("Detection", "RequireConfirmations", fallback=2)),
        clear_after_misses=max(1, parser.getint("Detection", "ClearAfterMisses", fallback=3)),
        cooldown_ms=max(0, parser.getint("Detection", "CooldownMs", fallback=30000)),
        click_on_match=parser.getboolean("Action", "ClickOnMatch", fallback=False),
        click_delay_ms=max(0, parser.getint("Action", "ClickDelayMs", fallback=150)),
        move_mouse_first=parser.getboolean("Action", "MoveMouseFirst", fallback=False),
        log_to_file=parser.getboolean("Debug", "LogToFile", fallback=True),
    )


def parse_scales(value: str) -> list[float]:
    scales = [float(part.strip()) for part in value.split(",") if part.strip()]
    if not scales or any(scale <= 0 for scale in scales):
        raise ValueError(f"Invalid scale list: {value}")
    return scales


def parse_threshold(value: str) -> float:
    threshold = float(value)
    if not 0.0 < threshold <= 1.0:
        raise ValueError(f"MatchThreshold must be between 0 and 1: {value}")
    return threshold


def parse_region(value: str) -> Region | None:
    if value.strip().lower() == "full":
        return None

    parts = [int(part.strip()) for part in value.split(",")]
    if len(parts) != 4:
        raise ValueError("SearchRegion must be `full` or `x,y,w,h`.")
    left, top, width, height = parts
    if width <= 0 or height <= 0:
        raise ValueError("SearchRegion width and height must be positive.")
    return Region(left=left, top=top, width=width, height=height)


def resolve_path(config_path: Path, raw_path: str) -> Path:
    path = Path(raw_path).expanduser()
    if path.is_absolute():
        return path
    return (config_path.parent / path).resolve()


def capture_screen(region: Region | None):
    if region is None:
        return pyautogui.screenshot()
    return pyautogui.screenshot(region=(region.left, region.top, region.width, region.height))


def send_pushover(config: Config, title: str, message: str) -> None:
    response = requests.post(
        "https://api.pushover.net/1/messages.json",
        data={
            "token": config.pushover_app_token,
            "user": config.pushover_user_key,
            "device": config.pushover_device,
            "title": title,
            "message": message,
            "priority": config.priority,
        },
        timeout=15,
    )
    response.raise_for_status()


def get_foreground_window_title() -> str:
    user32 = ctypes.windll.user32
    hwnd = user32.GetForegroundWindow()
    if not hwnd:
        return ""
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buffer, length + 1)
    return buffer.value


def get_foreground_process_name() -> str:
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    psapi = ctypes.windll.psapi

    hwnd = user32.GetForegroundWindow()
    if not hwnd:
        return ""

    pid = ctypes.c_ulong()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    process = kernel32.OpenProcess(0x1000 | 0x0400, False, pid.value)
    if not process:
        return ""

    try:
        buffer = ctypes.create_unicode_buffer(260)
        if psapi.GetModuleBaseNameW(process, None, buffer, len(buffer)) > 0:
            return buffer.value
        return ""
    finally:
        kernel32.CloseHandle(process)


def configure_logging(log_to_file: bool) -> None:
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if log_to_file:
        handlers.append(logging.FileHandler(LOG_PATH, encoding="utf-8"))

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)s | %(message)s",
        handlers=handlers,
    )


def main() -> int:
    config = load_config(CONFIG_PATH)
    configure_logging(config.log_to_file)
    logging.info("Loaded config from %s", CONFIG_PATH)
    watcher = ImageWatcher(config)
    watcher.run_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
