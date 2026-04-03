#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

global CONFIG_PATH := A_ScriptDir "\watch_image.ini"
global LOG_PATH := A_ScriptDir "\watch_image.log"
global gConfig := Map()
global gState := Map(
    "Paused", false,
    "Candidate", 0,
    "Alerted", false,
    "ConsecutiveMisses", 0,
    "LastAlertTick", 0,
    "PauseHotkey", "",
    "ManualScanHotkey", ""
)
global gGdipToken := 0

OnExit(ShutdownGdip)

try {
    LoadConfig(true)
    SetupTrayMenu()
    SetTimer(ScanOnce, gConfig["ScanIntervalMs"])
    Log("Watcher started.")
} catch as err {
    MsgBox("Startup failed:`n`n" err.Message, "watch_image.ahk", "Iconx")
    ExitApp(1)
}

ScanOnce()
return

ScanOnce(*) {
    global gConfig, gState

    if gState["Paused"] {
        return
    }

    try {
        match := FindImageOnScreen(gConfig)
    } catch as err {
        Log("Scan error: " err.Message)
        return
    }

    if IsObject(match) {
        gState["ConsecutiveMisses"] := 0

        previous := gState["Candidate"]
        if IsObject(previous) && IsWithinRadius(previous, match, gConfig["ConfirmRadiusPx"]) {
            match["Count"] := previous["Count"] + 1
        } else {
            match["Count"] := 1
        }

        gState["Candidate"] := match

        canNotify := !gState["Alerted"] && ((A_TickCount - gState["LastAlertTick"]) >= gConfig["CooldownMs"])
        if (match["Count"] >= gConfig["RequireConfirmations"]) && canNotify {
            HandleConfirmedMatch(match)
            gState["Alerted"] := true
            gState["LastAlertTick"] := A_TickCount
        }
        return
    }

    gState["Candidate"] := 0
    gState["ConsecutiveMisses"] += 1

    if gState["ConsecutiveMisses"] >= gConfig["ClearAfterMisses"] {
        if gState["Alerted"] {
            Log("Match cleared after " gState["ConsecutiveMisses"] " misses.")
        }
        gState["Alerted"] := false
    }
}

FindImageOnScreen(cfg) {
    region := cfg["SearchRegion"]

    for _, scale in cfg["Scales"] {
        width := Max(1, Round(cfg["BaseWidth"] * scale))
        height := Max(1, Round(cfg["BaseHeight"] * scale))
        options := "*" cfg["Variation"]

        if (width != cfg["BaseWidth"]) || (height != cfg["BaseHeight"]) {
            options .= " *w" width " *h" height
        }

        spec := options " " cfg["ImagePath"]
        foundX := 0
        foundY := 0

        if ImageSearch(&foundX, &foundY, region["Left"], region["Top"], region["Right"], region["Bottom"], spec) {
            return Map(
                "X", foundX,
                "Y", foundY,
                "Width", width,
                "Height", height,
                "Scale", scale,
                "Count", 1
            )
        }
    }

    return 0
}

HandleConfirmedMatch(match) {
    global gConfig

    centerX := match["X"] + Floor(match["Width"] / 2)
    centerY := match["Y"] + Floor(match["Height"] / 2)
    title := ""
    process := ""

    try title := WinGetTitle("A")
    try process := WinGetProcessName("A")

    message := "Found " gConfig["ImageLabel"]
        . " at (" centerX ", " centerY ")"
        . "`nScale: " Format("{:.2f}", match["Scale"])
        . "`nWindow: " title
        . "`nProcess: " process
        . "`nTime: " FormatTime(, "yyyy-MM-dd HH:mm:ss")

    try {
        SendPushover(gConfig, gConfig["NotificationTitle"], message)
        Log("Notification sent for match at (" centerX ", " centerY ").")
    } catch as err {
        Log("Notification failed: " err.Message)
    }

    if gConfig["ClickOnMatch"] {
        Sleep(gConfig["ClickDelayMs"])
        if gConfig["MoveMouseFirst"] {
            MouseMove(centerX, centerY, 0)
        }
        Click(centerX, centerY)
        Log("Clicked match at (" centerX ", " centerY ").")
    }
}

SendPushover(cfg, title, message) {
    request := ComObject("WinHttp.WinHttpRequest.5.1")
    request.Open("POST", "https://api.pushover.net/1/messages.json", false)
    request.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded")

    payload := BuildFormData(Map(
        "token", cfg["PushoverAppToken"],
        "user", cfg["PushoverUserKey"],
        "device", cfg["PushoverDevice"],
        "title", title,
        "message", message,
        "priority", cfg["Priority"]
    ))

    request.Send(payload)
    status := request.Status
    if (status < 200) || (status >= 300) {
        throw Error("Pushover returned HTTP " status ": " request.ResponseText)
    }
}

BuildFormData(fields) {
    parts := []
    for key, value in fields {
        if (value = "") {
            continue
        }
        parts.Push(UriEncode(key) "=" UriEncode(String(value)))
    }
    return JoinArray(parts, "&")
}

UriEncode(value) {
    bufSize := StrPut(value, "UTF-8")
    buf := Buffer(bufSize, 0)
    byteCount := StrPut(value, buf, "UTF-8") - 1
    encoded := ""

    Loop byteCount {
        b := NumGet(buf, A_Index - 1, "UChar")
        if ((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b = 0x2D || b = 0x2E || b = 0x5F || b = 0x7E) {
            encoded .= Chr(b)
        } else if (b = 0x20) {
            encoded .= "+"
        } else {
            encoded .= "%" Format("{:02X}", b)
        }
    }

    return encoded
}

IsWithinRadius(leftMatch, rightMatch, radius) {
    dx := Abs(leftMatch["X"] - rightMatch["X"])
    dy := Abs(leftMatch["Y"] - rightMatch["Y"])
    return (dx <= radius) && (dy <= radius)
}

LoadConfig(showSuccess := false) {
    global CONFIG_PATH, LOG_PATH, gConfig, gState

    if !FileExist(CONFIG_PATH) {
        throw Error("Missing config file: " CONFIG_PATH "`nCopy watch_image.ini.example to watch_image.ini and fill in your values.")
    }

    imagePath := ResolvePath(ReadIni("Detection", "ImagePath", "sample.png"))
    if !FileExist(imagePath) {
        throw Error("Configured image file does not exist: " imagePath)
    }

    dimensions := GetImageDimensions(imagePath)
    scales := ParseScales(ReadIni("Detection", "Scales", "0.85,0.95,1.00,1.10,1.20"))
    region := ParseRegion(ReadIni("Detection", "SearchRegion", "full"))

    nextConfig := Map(
        "PushoverAppToken", ReadIni("Pushover", "AppToken", ""),
        "PushoverUserKey", ReadIni("Pushover", "UserKey", ""),
        "PushoverDevice", ReadIni("Pushover", "Device", ""),
        "NotificationTitle", ReadIni("Pushover", "Title", "Screen match detected"),
        "Priority", ReadIni("Pushover", "Priority", "0"),
        "ImagePath", imagePath,
        "ImageLabel", ReadIni("Detection", "ImageLabel", FileNameOnly(imagePath)),
        "SearchRegion", region,
        "Variation", ParseInteger(ReadIni("Detection", "Variation", "30"), "Variation"),
        "Scales", scales,
        "ScanIntervalMs", Max(100, ParseInteger(ReadIni("Detection", "ScanIntervalMs", "500"), "ScanIntervalMs")),
        "ConfirmRadiusPx", Max(0, ParseInteger(ReadIni("Detection", "ConfirmRadiusPx", "20"), "ConfirmRadiusPx")),
        "RequireConfirmations", Max(1, ParseInteger(ReadIni("Detection", "RequireConfirmations", "2"), "RequireConfirmations")),
        "ClearAfterMisses", Max(1, ParseInteger(ReadIni("Detection", "ClearAfterMisses", "3"), "ClearAfterMisses")),
        "CooldownMs", Max(0, ParseInteger(ReadIni("Detection", "CooldownMs", "30000"), "CooldownMs")),
        "ClickOnMatch", ParseBool(ReadIni("Action", "ClickOnMatch", "0")),
        "ClickDelayMs", Max(0, ParseInteger(ReadIni("Action", "ClickDelayMs", "150"), "ClickDelayMs")),
        "MoveMouseFirst", ParseBool(ReadIni("Action", "MoveMouseFirst", "0")),
        "PauseHotkey", ReadIni("Hotkeys", "PauseToggle", ""),
        "ManualScanHotkey", ReadIni("Hotkeys", "ManualScan", ""),
        "LogToFile", ParseBool(ReadIni("Debug", "LogToFile", "1")),
        "BaseWidth", dimensions["Width"],
        "BaseHeight", dimensions["Height"],
        "LogPath", LOG_PATH
    )

    if (nextConfig["PushoverAppToken"] = "") || (nextConfig["PushoverUserKey"] = "") {
        throw Error("Pushover AppToken and UserKey are required in watch_image.ini.")
    }

    DisablePreviousHotkeys()
    gConfig := nextConfig
    SetupHotkeys()
    SetTimer(ScanOnce, 0)
    SetTimer(ScanOnce, gConfig["ScanIntervalMs"])
    gState["Candidate"] := 0
    gState["ConsecutiveMisses"] := 0
    gState["Alerted"] := false

    if showSuccess {
        Log("Config loaded from " CONFIG_PATH)
    }
}

ReadIni(section, key, defaultValue) {
    global CONFIG_PATH
    return Trim(IniRead(CONFIG_PATH, section, key, defaultValue), " `t`r`n")
}

ParseScales(value) {
    scales := []
    for _, part in StrSplit(value, ",") {
        trimmed := Trim(part)
        if (trimmed = "") {
            continue
        }
        scale := trimmed + 0.0
        if scale <= 0 {
            throw Error("Invalid scale value: " trimmed)
        }
        scales.Push(scale)
    }

    if scales.Length = 0 {
        throw Error("At least one scale is required.")
    }

    return scales
}

ParseRegion(value) {
    if StrLower(value) = "full" {
        return Map("Left", 0, "Top", 0, "Right", A_ScreenWidth - 1, "Bottom", A_ScreenHeight - 1)
    }

    parts := StrSplit(value, ",")
    if parts.Length != 4 {
        throw Error("SearchRegion must be `full` or `x,y,w,h`.")
    }

    left := ParseInteger(Trim(parts[1]), "SearchRegion left")
    top := ParseInteger(Trim(parts[2]), "SearchRegion top")
    width := ParseInteger(Trim(parts[3]), "SearchRegion width")
    height := ParseInteger(Trim(parts[4]), "SearchRegion height")

    if (width <= 0) || (height <= 0) {
        throw Error("SearchRegion width and height must be positive.")
    }

    return Map(
        "Left", left,
        "Top", top,
        "Right", left + width - 1,
        "Bottom", top + height - 1
    )
}

ParseInteger(value, label) {
    if !RegExMatch(value, "^-?\d+$") {
        throw Error("Invalid integer for " label ": " value)
    }
    return value + 0
}

ParseBool(value) {
    lowered := StrLower(Trim(value))
    return (lowered = "1") || (lowered = "true") || (lowered = "yes") || (lowered = "on")
}

ResolvePath(pathValue) {
    if RegExMatch(pathValue, "i)^[A-Z]:\\") || RegExMatch(pathValue, "^(\\\\|/)") {
        return pathValue
    }
    return A_ScriptDir "\" pathValue
}

FileNameOnly(pathValue) {
    SplitPath(pathValue, &name)
    return name
}

GetImageDimensions(pathValue) {
    global gGdipToken

    if !gGdipToken {
        input := Buffer(16, 0)
        NumPut("UInt", 1, input, 0)
        token := 0
        status := DllCall("gdiplus\GdiplusStartup", "UPtr*", &token, "Ptr", input.Ptr, "Ptr", 0, "UInt")
        if status != 0 {
            throw Error("GDI+ startup failed with status " status)
        }
        gGdipToken := token
    }

    bitmap := 0
    status := DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", pathValue, "Ptr*", &bitmap, "UInt")
    if status != 0 {
        throw Error("Could not load image metadata for " pathValue " (status " status ").")
    }

    width := 0
    height := 0
    DllCall("gdiplus\GdipGetImageWidth", "Ptr", bitmap, "UInt*", &width)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", bitmap, "UInt*", &height)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bitmap)

    return Map("Width", width, "Height", height)
}

ShutdownGdip(*) {
    global gGdipToken
    if gGdipToken {
        DllCall("gdiplus\GdiplusShutdown", "UPtr", gGdipToken)
        gGdipToken := 0
    }
}

SetupTrayMenu() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Pause", PauseWatcher)
    A_TrayMenu.Add("Resume", ResumeWatcher)
    A_TrayMenu.Add("Manual Scan", ManualScan)
    A_TrayMenu.Add("Reload Config", ReloadConfigAction)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", ExitScript)
}

SetupHotkeys() {
    global gConfig, gState

    pauseHotkey := gConfig["PauseHotkey"]
    scanHotkey := gConfig["ManualScanHotkey"]

    if (pauseHotkey != "") {
        Hotkey(pauseHotkey, TogglePause)
    }
    if (scanHotkey != "") {
        Hotkey(scanHotkey, ManualScan)
    }

    gState["PauseHotkey"] := pauseHotkey
    gState["ManualScanHotkey"] := scanHotkey
}

DisablePreviousHotkeys() {
    global gState

    if (gState["PauseHotkey"] != "") {
        try Hotkey(gState["PauseHotkey"], "Off")
    }
    if (gState["ManualScanHotkey"] != "") {
        try Hotkey(gState["ManualScanHotkey"], "Off")
    }

    gState["PauseHotkey"] := ""
    gState["ManualScanHotkey"] := ""
}

PauseWatcher(*) {
    global gState
    gState["Paused"] := true
    TrayTip("Watcher paused.", "watch_image", 1)
    Log("Watcher paused.")
}

ResumeWatcher(*) {
    global gState
    gState["Paused"] := false
    TrayTip("Watcher resumed.", "watch_image", 1)
    Log("Watcher resumed.")
}

TogglePause(*) {
    global gState
    if gState["Paused"] {
        ResumeWatcher()
    } else {
        PauseWatcher()
    }
}

ManualScan(*) {
    Log("Manual scan requested.")
    ScanOnce()
}

ReloadConfigAction(*) {
    try {
        LoadConfig()
        TrayTip("Config reloaded.", "watch_image", 1)
        Log("Config reloaded.")
    } catch as err {
        MsgBox("Config reload failed:`n`n" err.Message, "watch_image.ahk", "Iconx")
        Log("Config reload failed: " err.Message)
    }
}

ExitScript(*) {
    ExitApp()
}

Log(message) {
    global gConfig, LOG_PATH

    logEnabled := true
    if IsObject(gConfig) && gConfig.Has("LogToFile") {
        logEnabled := gConfig["LogToFile"]
    }
    if !logEnabled {
        return
    }

    timestamped := FormatTime(, "yyyy-MM-dd HH:mm:ss") " | " message "`n"
    FileAppend(timestamped, LOG_PATH, "UTF-8")
}

JoinArray(items, separator) {
    output := ""
    for index, item in items {
        if index > 1 {
            output .= separator
        }
        output .= item
    }
    return output
}
