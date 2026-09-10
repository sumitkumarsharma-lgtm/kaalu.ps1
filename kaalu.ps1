# ============================================================
#  KAALU - your black puppy desktop buddy
#  Pure PowerShell + WPF. No installs needed.
#  Left-click = menu | Drag = move | Double-click = bark
# ============================================================

# --- single instance guard ---
$script:mtx = New-Object System.Threading.Mutex($false, "KaaluDesktopPet")
if (-not $script:mtx.WaitOne(0)) { exit }

# --- terminate gate: if the user chose Terminate from the tray, Kaalu
#     stays OFF (every relaunch exits here) until a real system reboot,
#     then re-enables himself. ---
try {
    $script:__flag = Join-Path $PSScriptRoot "kaalu_terminated.flag"
    if (Test-Path $script:__flag) {
        $ft = (Get-Item $script:__flag).LastWriteTime
        $bt = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        if ($bt -lt $ft) {
            exit
        } else {
            Remove-Item $script:__flag -Force -ErrorAction SilentlyContinue
            try { & schtasks.exe /Change /TN 'KaaluDesktopBuddy' /ENABLE 2>$null | Out-Null } catch {}
        }
    }
} catch {}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic, System.Speech

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class KaaluWin {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

# Voice engine lives in C# so recognition events (background threads)
# never touch PowerShell - they just fill a thread-safe queue that the
# UI tick loop drains.
Add-Type -ReferencedAssemblies "System.Speech" -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Speech.Recognition;
public static class KaaluVoice {
    public static ConcurrentQueue<string> Queue = new ConcurrentQueue<string>();
    public static SpeechRecognitionEngine Engine;
    public static string Status = "off";
    public static double MinConfidence = 0.70;
    public static void Start(string[] phrases) {
        Stop();
        try {
            Engine = new SpeechRecognitionEngine();
            Choices c = new Choices(phrases);
            GrammarBuilder gb = new GrammarBuilder(c);
            Grammar g = new Grammar(gb);
            Engine.LoadGrammar(g);
            Engine.SetInputToDefaultAudioDevice();
            Engine.SpeechRecognized += (s, e) => {
                if (e.Result != null && e.Result.Confidence >= MinConfidence) {
                    Queue.Enqueue(e.Result.Text);
                }
            };
            Engine.RecognizeAsync(RecognizeMode.Multiple);
            Status = "on";
        } catch (Exception ex) {
            Status = "error: " + ex.Message;
        }
    }
    public static void Stop() {
        try {
            if (Engine != null) {
                Engine.RecognizeAsyncCancel();
                Engine.Dispose();
                Engine = null;
            }
        } catch {}
        string ignored;
        while (Queue.TryDequeue(out ignored)) {}
        Status = "off";
    }
}
"@

# Reads the system audio output PEAK level (0..1) via WASAPI, so Kaalu
# can feel the music. Reads the mix of whatever is playing - no app hook.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class KaaluAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator { }
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int mask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice dev);
    }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        int GetPeakValue(out float peak);
    }
    static IAudioMeterInformation meter;
    public static bool Init() {
        try {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
            IMMDevice dev;
            if (en.GetDefaultAudioEndpoint(0, 0, out dev) != 0 || dev == null) return false;
            Guid iid = typeof(IAudioMeterInformation).GUID;
            object o;
            if (dev.Activate(ref iid, 1, IntPtr.Zero, out o) != 0) return false;
            meter = (IAudioMeterInformation)o;
            return meter != null;
        } catch { return false; }
    }
    public static float Peak() {
        try {
            if (meter == null) { if (!Init()) return 0f; }
            float p; meter.GetPeakValue(out p); return p;
        } catch { meter = null; return 0f; }
    }
}
"@

# Free-form dictation engine (offline) - Kaalu writes down what you say.
Add-Type -ReferencedAssemblies "System.Speech" -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Speech.Recognition;
public static class KaaluDictation {
    public static ConcurrentQueue<string> Queue = new ConcurrentQueue<string>();
    public static SpeechRecognitionEngine Engine;
    public static string Status = "off";
    public static void Start() {
        Stop();
        try {
            Engine = new SpeechRecognitionEngine();
            Engine.LoadGrammar(new DictationGrammar());
            Engine.SetInputToDefaultAudioDevice();
            Engine.SpeechRecognized += (s, e) => {
                if (e.Result != null && e.Result.Text != null && e.Result.Text.Length > 0) {
                    Queue.Enqueue(e.Result.Text);
                }
            };
            Engine.RecognizeAsync(RecognizeMode.Multiple);
            Status = "on";
        } catch (Exception ex) { Status = "error: " + ex.Message; }
    }
    public static void Stop() {
        try { if (Engine != null) { Engine.RecognizeAsyncCancel(); Engine.Dispose(); Engine = null; } } catch {}
        string ig; while (Queue.TryDequeue(out ig)) {}
        Status = "off";
    }
}
"@

function Send-VKey([byte]$vk) {
    [KaaluWin]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
    [KaaluWin]::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
}

# ------------------------------------------------------------
# Training memory (persists between sessions)
# ------------------------------------------------------------
$script:dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:memFile = Join-Path $script:dir "kaalu_memory.json"
$script:xp = 0
$script:learned = @()
$script:treatTime = [DateTime]::MinValue
$script:voiceOn = $true
$script:ttsOn = $true
$script:lang = "hi"
$script:musicOn = $true
if (Test-Path $script:memFile) {
    try {
        $m = Get-Content $script:memFile -Raw | ConvertFrom-Json
        $script:xp = [int]$m.xp
        $script:learned = @($m.learned | Where-Object { $_ })
        if ($m.PSObject.Properties['voice']) { $script:voiceOn = [bool]$m.voice }
        if ($m.PSObject.Properties['tts']) { $script:ttsOn = [bool]$m.tts }
        if ($m.PSObject.Properties['lang']) { $script:lang = [string]$m.lang }
        if ($m.PSObject.Properties['music']) { $script:musicOn = [bool]$m.music }
    } catch {}
}

function Save-Memory {
    try {
        @{ xp = $script:xp; learned = @($script:learned); voice = $script:voiceOn; tts = $script:ttsOn; lang = $script:lang; music = $script:musicOn } | ConvertTo-Json | Set-Content $script:memFile -Encoding UTF8
    } catch {}
}

# Multilingual helper: Bhojpuri -> Hindi -> English fallback.
# (Bhojpuri speakers understand Hindi, so untranslated strings fall back.)
function TR([string]$en, [string]$hi, [string]$bho = "") {
    if ($script:lang -eq "bho") {
        if ($bho) { return $bho }
        if ($hi) { return $hi }
        return $en
    }
    if ($script:lang -eq "hi" -and $hi) { return $hi }
    return $en
}

$script:TRICKS = @(
    @{ id = "shake";    name = "Shake / Hi-five 🐾"; xp = 20 },
    @{ id = "rollover"; name = "Roll over 🔄";       xp = 50 },
    @{ id = "playdead"; name = "Play dead 💀";       xp = 90 },
    @{ id = "dance";    name = "Dance 💃";           xp = 140 },
    @{ id = "howl";     name = "Howl 🌙";            xp = 200 },
    @{ id = "fetch";    name = "Fetch 🎾";           xp = 270 },
    @{ id = "dig";      name = "Dig / Khudai 🕳";    xp = 340 },
    @{ id = "zoomies";  name = "Zoomies / Bhaago 💨"; xp = 420 }
)

function Get-Level { return (1 + @($script:learned).Count) }

function Next-Trick {
    foreach ($tr in $script:TRICKS) {
        if ($script:learned -notcontains $tr.id) { return $tr }
    }
    return $null
}

# ------------------------------------------------------------
# Palette (case-distinct letters only; PS hashtables ignore case)
# ------------------------------------------------------------
$script:PAL = @{
    'K' = @(38, 38, 46)     # black fur
    'D' = @(20, 20, 26)     # dark shade / ear / paws
    'W' = @(245, 245, 250)  # white chest / glint
    'A' = @(198, 124, 43)   # amber eyes
    'M' = @(58, 58, 68)     # muzzle gray
    'N' = @(10, 10, 12)     # nose
    'P' = @(255, 125, 160)  # pink tongue
    'R' = @(229, 72, 77)    # red collar / roof
    'G' = @(255, 197, 61)   # gold tag / bone
    'B' = @(139, 90, 43)    # house walls (brown)
    'T' = @(90, 58, 29)     # house trim (dark brown)
    'U' = @(79, 163, 227)   # water (blue)
    'Y' = @(255, 217, 102)  # warm lamp light
    'C' = @(44, 62, 91)     # hero cape + cowl (dark blue)
}

# ------------------------------------------------------------
# Pixel art (faces RIGHT; rows auto-padded to 26x18)
# ------------------------------------------------------------
$script:ART = @{}

$script:ART['idle1'] = @(
    "",
    "................KKKK",
    "...............KKKKKKKK",
    "...............DDKKKKKKK",
    "...............DDKKAAKKKM",
    "..KK...........DKKKKKMMMN",
    "..KK...........KKKKKKKMM",
    "...KK..........KKKKKK",
    "....KKKKKKKKKKKRRRRK",
    "...KKKKKKKKKKKKKGKK",
    "...KKKKKKKKKKKWWWKK",
    "...KKKKKKKKKKKKWKKK",
    "....KKKKKKKKKKKKKK",
    ".....KK..KK..KK.KK",
    ".....KK..KK..KK.KK",
    ".....KK..KK..KK.KK",
    ".....DD..DD..DD.DD"
)

$script:ART['idle2'] = @(
    "",
    "................KKKK",
    "...............KKKKKKKK",
    "...............DDKKKKKKK",
    "...............DDKKAAKKKM",
    "...............DKKKKKMMMN",
    ".KK............KKKKKKKMM",
    "..KK...........KKKKKK",
    "....KKKKKKKKKKKRRRRK",
    "...KKKKKKKKKKKKKGKK",
    "...KKKKKKKKKKKWWWKK",
    "...KKKKKKKKKKKKWKKK",
    "....KKKKKKKKKKKKKK",
    ".....KK..KK..KK.KK",
    ".....KK..KK..KK.KK",
    ".....KK..KK..KK.KK",
    ".....DD..DD..DD.DD"
)

$script:ART['runA'] = @(
    "",
    "................KKKK",
    "...............KKKKKKKK",
    "...............DDKKKKKKK",
    "...............DDKKAAKKKM",
    "...............DKKKKKMMMN",
    ".KKK...........KKKKKKKMM",
    "...KK..........KKKKKK",
    "....KKKKKKKKKKKRRRRK",
    "...KKKKKKKKKKKKKGKK",
    "...KKKKKKKKKKKWWWKK",
    "...KKKKKKKKKKKKWKKK",
    "....KKKKKKKKKKKKKK",
    "....KK...KK..KK...KK",
    "....KK...KK..KK...KK",
    "....DD...DD..DD...DD",
    ""
)

$script:ART['runB'] = @(
    "",
    "................KKKK",
    "...............KKKKKKKK",
    "...............DDKKKKKKK",
    "...............DDKKAAKKKM",
    "..KK...........DKKKKKMMMN",
    "..KK...........KKKKKKKMM",
    "...KK..........KKKKKK",
    "....KKKKKKKKKKKRRRRK",
    "...KKKKKKKKKKKKKGKK",
    "...KKKKKKKKKKKWWWKK",
    "...KKKKKKKKKKKKWKKK",
    "....KKKKKKKKKKKKKK",
    "......KKKK....KKKK",
    "......KKKK....KKKK",
    "......DDDD....DDDD",
    ""
)

$script:ART['sit'] = @(
    "",
    "................KKKK",
    "...............KKKKKKKK",
    "...............DDKKKKKKK",
    "...............DDKKAAKKKM",
    "...............DKKKKKMMMN",
    "...............KKKKKKKMM",
    "................KKKKKK",
    "...............RRRRR",
    "..............KKGKK",
    "........KKKKKKKKKKK",
    ".......KKKKKKKKWKKK",
    "......KKKKKKKKKKKKK",
    ".....KKKKKKKKKKKKKK",
    ".....KKKKKKKKKKKKKK",
    "..KKKKKKKKK.....KK",
    ".....DDD........DD",
    ""
)

$script:ART['sleep1'] = @(
    "", "", "", "", "", "", "", "", "",
    "...............KKKKKKKK",
    "..............KDDKKKKKMM",
    "....KKKKKKKKKKKKKDDKKMMN",
    "...KKKKKKKKKKKKKKKKKKKKK",
    "...KKKKKKKKKKKKKKKKKKKK",
    "....DDDDDDDDDDDDDDDDDD",
    "", ""
)

$script:ART['sleep2'] = @(
    "", "", "", "", "", "", "", "", "", "",
    "...............KKKKKKKK",
    "..............KDDKKKKKMM",
    "...KKKKKKKKKKKKKKDDKKMMN",
    "...KKKKKKKKKKKKKKKKKKKK",
    "....DDDDDDDDDDDDDDDDDD",
    "", ""
)

$script:ART['bark'] = @(
    "",
    "................KKKK",
    "...............KKKKKKKK",
    "...............DDKKKKKKK",
    "...............DDKKAAKKKM",
    "..KK...........DKKKKKMMMN",
    "..KK...........KKKKKKKM.P",
    "...KK..........KKKKKKP",
    "....KKKKKKKKKKKRRRRK",
    "...KKKKKKKKKKKKKGKK",
    "...KKKKKKKKKKKWWWKK",
    "...KKKKKKKKKKKKWKKK",
    "....KKKKKKKKKKKKKK",
    ".....KK..KK..KK.KK",
    ".....KK..KK..KK.KK",
    ".....KK..KK..KK.KK",
    ".....DD..DD..DD.DD"
)

$script:ART['happy'] = @(
    "",
    "................KKKK",
    "...............KKKKKKKK",
    "...............DDKKKKKKK",
    "...............DDKKAAKKKM",
    "...............DKKKKKMMMN",
    ".KK............KKKKKKKMM",
    "..KK...........KKKKKKP",
    "....KKKKKKKKKKKRRRRK",
    "...KKKKKKKKKKKKKGKK",
    "...KKKKKKKKKKKWWWKK",
    "...KKKKKKKKKKKKWKKK",
    "....KKKKKKKKKKKKKK",
    ".....KK..KK..KK.KK",
    ".....KK..KK..KK.KK",
    ".....KK..KK..KK.KK",
    ".....DD..DD..DD.DD"
)

$script:ART['sitpaw'] = @(
    "",
    "................KKKK",
    "...............KKKKKKKK",
    "...............DDKKKKKKK",
    "...............DDKKAAKKKM",
    "...............DKKKKKMMMN",
    "...............KKKKKKKMM",
    "................KKKKKK",
    "...............RRRRR",
    "..............KKGKK",
    "........KKKKKKKKKKK.KK",
    ".......KKKKKKKKWKKKKK",
    "......KKKKKKKKKKKKK",
    ".....KKKKKKKKKKKKKK",
    ".....KKKKKKKKKKKKKK",
    "..KKKKKKKKK.....KK",
    ".....DDD........DD",
    ""
)

$script:ART['dead'] = @(
    "", "", "", "", "", "", "", "", "", "", "",
    "......KK..KK..KK.KK",
    "......KK..KK..KK.KK",
    "....KKKKKKKWWKKKKKKK",
    "...KKKKKKKKKKKKKKKKKKKMM",
    "....KKKKKKKKKKKKKKKKK.P",
    "", ""
)

$script:ART['dig1'] = @(
    "", "", "", "", "",
    "....KK",
    "...KK",
    "...KKKKKK",
    "..KKKKKKKKKK",
    "..KKKKKKKKKKKKK",
    "...KKKKKKKKKKKKKKKK",
    "....KK..KKKKKKKKKKDDK",
    "....KK..KKKKKKKKKKKKKK",
    "....DD..KKK..KKKKKKKKMMN",
    ".........DDD....KKKK.MM",
    "................DDDD",
    "", ""
)

$script:ART['dig2'] = @(
    "", "", "", "",
    "....KK",
    "...KK",
    "...KKKKKK",
    "..KKKKKKKKKK",
    "..KKKKKKKKKKKKK...M",
    "...KKKKKKKKKKKKKKKK..M",
    "....KK..KKKKKKKKKKDDK..M",
    "....KK..KKKKKKKKKKKKKK",
    "....DD...KKK..KKKKKKKMMN",
    "..........DDD..KKKK.MM",
    "...............DDDD",
    "", ""
)

$script:ART['fly1'] = @(
    "", "",
    "....................C...C",
    ".....CCCCCCCCCC....CC..CC",
    "...CCCCCCCCCC.....CCCCCCCC",
    "..CCCCCCCC........CCAACCCC",
    "....KKKKKKKKKKKKKKKKKKMMMN",
    "....KKKKKKKKKKKKKKKKKKKK",
    "KKKKKKKKKKKKKKKKKKKK.KKKKK",
    ".KKKKKKKKKWWWWKKKKKK",
    ".....DDDDDDDDDDDDDD",
    "", ""
)

$script:ART['fly2'] = @(
    "", "",
    "....................C...C",
    "...................CC..CC",
    ".....CCCCCCCCCC...CCCCCCCC",
    "...CCCCCCCCC......CCAACCCC",
    "....KKKKKKKKKKKKKKKKKKMMMN",
    "....KKKKKKKKKKKKKKKKKKKK",
    "KKK.KKKKKKKKKKKKKKKK..KKKK",
    ".KKKKKKKKKWWWWKKKKKK",
    ".....DDDDDDDDDDDDDD",
    "", ""
)

# ------------------------------------------------------------
# Frame builder: pixel map -> frozen WriteableBitmap
# ------------------------------------------------------------
$script:GW = 26; $script:GH = 18

function New-PetFrame([string[]]$rows, [bool]$mirror) {
    $w = $script:GW; $h = $script:GH
    $bmp = New-Object Windows.Media.Imaging.WriteableBitmap($w, $h, 96, 96, ([Windows.Media.PixelFormats]::Bgra32), $null)
    $stride = $w * 4
    $px = New-Object byte[] ($stride * $h)
    for ($y = 0; $y -lt $h; $y++) {
        $row = ""
        if ($y -lt $rows.Count -and $rows[$y]) { $row = $rows[$y] }
        $row = $row.PadRight($w, '.')
        if ($row.Length -gt $w) { $row = $row.Substring(0, $w) }
        if ($mirror) { $a = $row.ToCharArray(); [Array]::Reverse($a); $row = -join $a }
        for ($x = 0; $x -lt $w; $x++) {
            $key = [string]$row[$x]
            if ($key -cne '.' -and $script:PAL.ContainsKey($key)) {
                $col = $script:PAL[$key]
                $i = ($y * $stride) + ($x * 4)
                $px[$i]     = [byte]$col[2]   # B
                $px[$i + 1] = [byte]$col[1]   # G
                $px[$i + 2] = [byte]$col[0]   # R
                $px[$i + 3] = [byte]255       # A
            }
        }
    }
    $rect = New-Object Windows.Int32Rect(0, 0, $w, $h)
    $bmp.WritePixels($rect, $px, $stride, 0)
    $bmp.Freeze()
    return $bmp
}

$script:FRAMES = @{}
foreach ($name in @($script:ART.Keys)) {
    $script:FRAMES["$name`_R"] = New-PetFrame $script:ART[$name] $false
    $script:FRAMES["$name`_L"] = New-PetFrame $script:ART[$name] $true
}

# ------------------------------------------------------------
# Pet window
# ------------------------------------------------------------
$script:SCALE = 5
$script:PW = $script:GW * $script:SCALE
$script:PH = $script:GH * $script:SCALE

$script:win = New-Object Windows.Window
$script:win.Title = "Kaalu"
$script:win.WindowStyle = "None"
$script:win.AllowsTransparency = $true
$script:win.Background = [Windows.Media.Brushes]::Transparent
$script:win.Topmost = $true
$script:win.ShowInTaskbar = $false
$script:win.ResizeMode = "NoResize"
$script:win.SizeToContent = "Manual"
$script:win.Width = $script:PW
$script:win.Height = $script:PH
$script:win.ShowActivated = $false

$script:img = New-Object Windows.Controls.Image
$script:img.Source = $script:FRAMES['idle1_R']
$script:img.Stretch = "Fill"
[Windows.Media.RenderOptions]::SetBitmapScalingMode($script:img, [Windows.Media.BitmapScalingMode]::NearestNeighbor)
$script:rot = New-Object Windows.Media.RotateTransform(0)
$script:img.RenderTransform = $script:rot
$script:img.RenderTransformOrigin = New-Object Windows.Point(0.5, 0.5)
$script:win.Content = $script:img

$script:area = [Windows.SystemParameters]::WorkArea
$script:groundY = $script:area.Bottom - $script:PH
$script:win.Left = $script:area.Left + [Math]::Floor($script:area.Width * 0.6)
$script:win.Top = $script:groundY

# ------------------------------------------------------------
# Speech bubble window
# ------------------------------------------------------------
$script:bub = New-Object Windows.Window
$script:bub.WindowStyle = "None"
$script:bub.AllowsTransparency = $true
$script:bub.Background = [Windows.Media.Brushes]::Transparent
$script:bub.Topmost = $true
$script:bub.ShowInTaskbar = $false
$script:bub.ResizeMode = "NoResize"
$script:bub.SizeToContent = "WidthAndHeight"
$script:bub.IsHitTestVisible = $false
$script:bub.Focusable = $false
$script:bub.ShowActivated = $false

$script:bubText = New-Object Windows.Controls.TextBlock
$script:bubText.Text = ""
$script:bubText.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI, Segoe UI Emoji")
$script:bubText.FontSize = 14
$script:bubText.FontWeight = "SemiBold"
$script:bubText.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(30,30,36))
$script:bubText.TextWrapping = "Wrap"
$script:bubText.MaxWidth = 260
$script:bubText.Margin = "12,8,12,8"

$script:bubBorder = New-Object Windows.Controls.Border
$script:bubBorder.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromArgb(242,255,255,255))
$script:bubBorder.CornerRadius = "12"
$script:bubBorder.BorderBrush = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(38,38,46))
$script:bubBorder.BorderThickness = "2"
$script:bubBorder.Child = $script:bubText
$script:bub.Content = $script:bubBorder

$script:bubbleTicks = 0

# ------------------------------------------------------------
# Fetch ball window
# ------------------------------------------------------------
$script:ballWin = New-Object Windows.Window
$script:ballWin.WindowStyle = "None"
$script:ballWin.AllowsTransparency = $true
$script:ballWin.Background = [Windows.Media.Brushes]::Transparent
$script:ballWin.Topmost = $true
$script:ballWin.ShowInTaskbar = $false
$script:ballWin.ResizeMode = "NoResize"
$script:ballWin.Width = 26
$script:ballWin.Height = 26
$script:ballWin.IsHitTestVisible = $false
$script:ballWin.Focusable = $false
$script:ballWin.ShowActivated = $false

$script:ballShape = New-Object Windows.Controls.Border
$script:ballShape.Width = 22
$script:ballShape.Height = 22
$script:ballShape.CornerRadius = "11"
$script:ballShape.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(255, 140, 66))
$script:ballShape.BorderBrush = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(200, 90, 30))
$script:ballShape.BorderThickness = "2"
$script:ballWin.Content = $script:ballShape

# ------------------------------------------------------------
# Kaalu's doghouse
# ------------------------------------------------------------
function New-Bitmap([string[]]$rows, [int]$w, [int]$h) {
    $bmp = New-Object Windows.Media.Imaging.WriteableBitmap($w, $h, 96, 96, ([Windows.Media.PixelFormats]::Bgra32), $null)
    $stride = $w * 4
    $px = New-Object byte[] ($stride * $h)
    for ($y = 0; $y -lt $h; $y++) {
        $row = ""
        if ($y -lt $rows.Count -and $rows[$y]) { $row = $rows[$y] }
        $row = $row.PadRight($w, '.')
        if ($row.Length -gt $w) { $row = $row.Substring(0, $w) }
        for ($x = 0; $x -lt $w; $x++) {
            $key = [string]$row[$x]
            if ($key -cne '.' -and $script:PAL.ContainsKey($key)) {
                $col = $script:PAL[$key]
                $i = ($y * $stride) + ($x * 4)
                $px[$i]     = [byte]$col[2]
                $px[$i + 1] = [byte]$col[1]
                $px[$i + 2] = [byte]$col[0]
                $px[$i + 3] = [byte]255
            }
        }
    }
    $rect = New-Object Windows.Int32Rect(0, 0, $w, $h)
    $bmp.WritePixels($rect, $px, $stride, 0)
    $bmp.Freeze()
    return $bmp
}

# house (lights OFF) with bone + water bowl in the yard (34 wide)
$script:HOUSEART_OFF = @(
    "............RR",
    "...........RRRR",
    "..........RRRRRR",
    ".........RRRRRRRR",
    "........RRRRRRRRRR",
    ".......RRRRRRRRRRRR",
    "......RRRRRRRRRRRRRR",
    ".....RRRRRRRRRRRRRRRR",
    "....RRRRRRRRRRRRRRRRRR",
    "...RRRRRRRRRRRRRRRRRRRR",
    "..TTTTTTTTTTTTTTTTTTTTTT",
    "....BBBBBBBBBBBBBBBBBB",
    "....BBBBBBGGGGGGBBBBBB",
    "....BBBBBBBBBBBBBBBBBB",
    "....BBBBBDDDDDDDDBBBBB",
    "....BBBBDDDDDDDDDDBBBB",
    "....BBBBDDDDDDDDDDBBBB",
    "....BBBBDDDDDDDDDDBBBB",
    "....BBBBDDDDDDDDDDBBBB....GG..GG",
    "....BBBBDDDDDDDDDDBBBB....GGGGGG",
    "....BBBBDDDDDDDDDDBBBB...MUUUUUM",
    "...TTTTTTTTTTTTTTTTTTTT..MMMMMMM"
)

# lights ON: doorway glows warm + Kaalu curled up inside
$script:HOUSEART_ON = @(
    "............RR",
    "...........RRRR",
    "..........RRRRRR",
    ".........RRRRRRRR",
    "........RRRRRRRRRR",
    ".......RRRRRRRRRRRR",
    "......RRRRRRRRRRRRRR",
    ".....RRRRRRRRRRRRRRRR",
    "....RRRRRRRRRRRRRRRRRR",
    "...RRRRRRRRRRRRRRRRRRRR",
    "..TTTTTTTTTTTTTTTTTTTTTT",
    "....BBBBBBBBBBBBBBBBBB",
    "....BBBBBBGGGGGGBBBBBB",
    "....BBBBBBBBBBBBBBBBBB",
    "....BBBBBYYYYYYYYBBBBB",
    "....BBBBYYYYYYYYYYBBBB",
    "....BBBBYYYYYYYYYYBBBB",
    "....BBBBYYYYYYYYYYBBBB",
    "....BBBBYYKKKKKKYYBBBB....GG..GG",
    "....BBBBYKKKKKKKKYBBBB....GGGGGG",
    "....BBBBYKKKKKKKKYBBBB...MUUUUUM",
    "...TTTTTTTTTTTTTTTTTTTT..MMMMMMM"
)

$script:inHouse = $false
$script:awayTicks = 0
$script:houseWin = New-Object Windows.Window
$script:houseWin.Title = "Kaalu House"
$script:houseWin.WindowStyle = "None"
$script:houseWin.AllowsTransparency = $true
$script:houseWin.Background = [Windows.Media.Brushes]::Transparent
$script:houseWin.Topmost = $true
$script:houseWin.ShowInTaskbar = $false
$script:houseWin.ResizeMode = "NoResize"
$script:houseWin.Width = 34 * 5
$script:houseWin.Height = 22 * 5
$script:houseWin.ShowActivated = $false

$script:HOUSE_OFF_BMP = New-Bitmap $script:HOUSEART_OFF 34 22
$script:HOUSE_ON_BMP = New-Bitmap $script:HOUSEART_ON 34 22

$script:houseImg = New-Object Windows.Controls.Image
$script:houseImg.Source = $script:HOUSE_OFF_BMP
$script:houseImg.Stretch = "Fill"
[Windows.Media.RenderOptions]::SetBitmapScalingMode($script:houseImg, [Windows.Media.BitmapScalingMode]::NearestNeighbor)
$script:houseWin.Content = $script:houseImg

function Set-HouseLight([bool]$on) {
    $script:houseImg.Source = $(if ($on) { $script:HOUSE_ON_BMP } else { $script:HOUSE_OFF_BMP })
}

function Get-DoorX {
    # door center is at pixel column 13 of the 34-wide art (x5 scale = 65)
    return $script:houseWin.Left + 65 - ($script:PW / 2)
}

# --- Super Kaalu flight ---
$script:flyTicks = 0
$script:flyTX = 0.0
$script:flyTY = 0.0

# --- auto-feeder ---
$script:treatTicks = 0

function Start-Flight {
    if ($script:state -like "fly*") { return }
    Say (TR "🦇 Mask on, cape on... SUPER KAALU!`nTo the skies!" "🦇 Mask on, cape on... SUPER KAALU!`nUdaan bhario!") 30
    Play-Bark
    $script:flyTX = $script:area.Left + $script:rand.Next([int][Math]::Max(1, $script:area.Width - $script:PW))
    $script:flyTY = $script:area.Top + 30
    $script:flyTicks = 0
    Enter-State "flyout" 100
}

$script:houseWin.Add_MouseLeftButtonDown({
    $before = $script:houseWin.Left
    try { $script:houseWin.DragMove() } catch {}
    $script:houseWin.Top = $script:area.Bottom - $script:houseWin.Height
    if ([Math]::Abs($script:houseWin.Left - $before) -lt 5) {
        if ($script:state -eq "sleephome") {
            Enter-State "idle" 30
            Say (TR "I'm up! I'm up! 🐶" "Uth gaya, uth gaya! 🐶") 20
        } else {
            Say (TR "That's my house! 🏠" "Ye mera ghar hai! 🏠") 20
        }
    }
})

function Move-Bubble {
    if ($script:bub.IsVisible) {
        $ax = $script:win.Left; $aw = $script:PW; $ay = $script:win.Top
        if ($script:inHouse) {
            $ax = $script:houseWin.Left; $aw = $script:houseWin.Width; $ay = $script:houseWin.Top
        }
        $script:bub.Left = $ax + $aw - 10
        $script:bub.Top = $ay - $script:bub.ActualHeight + 14
        if ($script:bub.Left + $script:bub.ActualWidth -gt $script:area.Right) {
            $script:bub.Left = $ax - $script:bub.ActualWidth + 10
        }
        if ($script:bub.Top -lt $script:area.Top) { $script:bub.Top = $script:area.Top }
    }
}

# ------------------------------------------------------------
# Kaalu's speaking voice (offline Windows text-to-speech)
# ------------------------------------------------------------
$script:tts = $null
try {
    $script:tts = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $script:tts.Volume = 100
    try { $script:tts.SelectVoice("Microsoft Zira Desktop") }
    catch {
        try { $script:tts.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::Female, [System.Speech.Synthesis.VoiceAge]::Child) } catch {}
    }
} catch {}

function Speak-Text([string]$msg) {
    if (-not $script:ttsOn -or -not $script:tts -or $script:transcribing) { return }
    try {
        $clean = $msg -replace "(\r?\n)+", ". "
        $clean = $clean -replace "[^\p{L}\p{Nd}\s\.,:;!\?%'-]", " "
        $clean = ($clean -replace "\s{2,}", " ").Trim()
        if (-not $clean) { return }
        $esc = [System.Security.SecurityElement]::Escape($clean)
        # Default voice: deep dramatic male (Gadar style) - David via SSML,
        # falling back to deep-pitched Zira, then plain speech.
        $ssml = "<speak version=""1.0"" xmlns=""http://www.w3.org/2001/10/synthesis"" xml:lang=""en-US""><voice name=""Microsoft David Desktop""><prosody pitch=""-2st"" rate=""medium"">$esc</prosody></voice></speak>"
        $ssmlFb = "<speak version=""1.0"" xmlns=""http://www.w3.org/2001/10/synthesis"" xml:lang=""en-US""><prosody pitch=""-8st"" rate=""medium"">$esc</prosody></speak>"
        $script:tts.SpeakAsyncCancelAll()
        try { $script:tts.SpeakSsmlAsync($ssml) | Out-Null }
        catch {
            try { $script:tts.SpeakSsmlAsync($ssmlFb) | Out-Null }
            catch { $script:tts.SpeakAsync($clean) | Out-Null }
        }
    } catch {}
}

function Say([string]$msg, [int]$ticks = 45, [bool]$noVoice = $false) {
    # lead a command reply with "Zee Maalik!" (one-shot, set by Obey-Command)
    if ($script:leadMalik -and -not $noVoice) {
        $script:leadMalik = $false
        $msg = (TR "Zee Maalik! " "Zee Maalik! " "Zee Maalik ho! ") + $msg
    }
    $script:bubText.Text = $msg
    if (-not $script:bub.IsVisible) { $script:bub.Show() }
    $script:bub.UpdateLayout()
    Move-Bubble
    $script:bubbleTicks = $ticks
    try { $script:bub.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render) } catch {}
    if (-not $noVoice) { Speak-Text $msg }
}

# ------------------------------------------------------------
# Sounds
# ------------------------------------------------------------
function Play-Bark {
    try {
        [System.Threading.Tasks.Task]::Run([Action]{
            try {
                [Console]::Beep(650, 70); Start-Sleep -Milliseconds 40
                [Console]::Beep(480, 110)
            } catch {}
        }) | Out-Null
    } catch {}
}

function Play-Alarm {
    try {
        [System.Threading.Tasks.Task]::Run([Action]{
            try {
                for ($i = 0; $i -lt 3; $i++) {
                    [Console]::Beep(700, 80); [Console]::Beep(520, 120)
                    Start-Sleep -Milliseconds 150
                }
            } catch {}
        }) | Out-Null
    } catch {}
}

function Play-Howl {
    try {
        [System.Threading.Tasks.Task]::Run([Action]{
            try {
                [Console]::Beep(350, 120); [Console]::Beep(420, 120)
                [Console]::Beep(500, 120); [Console]::Beep(600, 160)
                [Console]::Beep(700, 480); [Console]::Beep(500, 220)
            } catch {}
        }) | Out-Null
    } catch {}
}

$script:BARKS = @("Woof woof! 🐾", "Bhow bhow! 🐶", "WOOF! 🦴", "Arf arf! 🐾")
$script:BARKS_HI = @("Bhow bhow! 🐾", "BHOW! 🐶", "Bhow bhow bhow! 🦴", "Woof! Matlab bhow! 🐾")
$script:JOKES = @(
    "Why do dogs float? Because they're good buoys! 🦴",
    "What's my favorite instrument? The trom-BONE! 🎺",
    "Why did I sit in the shade? Didn't want to be a hot dog! 🌭",
    "What do you call a dog magician? A labracadabrador! 🎩",
    "I'm not barking at nothing - I'm debugging the yard! 🐛",
    "Why are dogs bad dancers? Two left feet... twice! 🕺",
    "My favorite city? New Yorkie! 🗽",
    "I chased my tail for an hour. Still no promotion. 💼"
)
$script:JOKES_HI = @(
    "Main hot dog kyun nahi banta? Kyunki main COOL dog hoon! 😎",
    "Computer kharab kyun kiya? Mujhe BARK-up lena tha! 💾",
    "Mera favourite gaana? Who let the dogs out! 🎵",
    "Boss promotion nahi dete... kehte hain main bahut bhonkta hoon! 💼",
    "Doctor bola main bilkul fit hoon... PAW-sitively fit! 🐾",
    "Maine homework kha liya. Sorry nahi bolunga, tasty tha! 📚",
    "Billi se race haar gaya... par participation treat toh mila! 🏅",
    "Mailman se dosti kar li. Ab woh letter nahi, biscuit laata hai! ✉️"
)

$script:BARKS_BHO = @("Bhow bhow ho! 🐾", "BHOW ho! 🐶", "Bhow bhow bhow! 🦴", "Woof! Maane bhow ho! 🐾")
$script:JOKES_BHO = @(
    "Hum hot dog kaahe na baani? Kaahe ki hum COOL dog baani! 😎",
    "Doctar bolal hum ekdam theek baani... PAW-sitively fit! 🐾",
    "Malik promotion na dela... kahela hum bahute bhaunkeni! 💼",
    "Billi se race haar gaili... baaki treat ta milal! 🏅",
    "Hum homework kha gaili. Sorry na bolab, swaadist rahe! 📚",
    "Mailman se dosti kar leni. Ab u chitthi na, biscuit laavela! ✉️"
)

function Pick-Bark {
    $list = $script:BARKS
    if ($script:lang -eq "hi") { $list = $script:BARKS_HI }
    elseif ($script:lang -eq "bho") { $list = $script:BARKS_BHO }
    return $list[$script:rand.Next($list.Count)]
}

function Pick-Joke {
    $list = $script:JOKES
    if ($script:lang -eq "hi") { $list = $script:JOKES_HI }
    elseif ($script:lang -eq "bho") { $list = $script:JOKES_BHO }
    return $list[$script:rand.Next($list.Count)]
}

# ------------------------------------------------------------
# State machine
# ------------------------------------------------------------
$script:state = "idle"
$script:stateTicks = 30
$script:tick = 0
$script:facing = "R"
$script:targetX = $script:win.Left
$script:roam = $true
$script:paused = $false
$script:muted = $false
$script:jumpTick = 0
$script:rand = New-Object System.Random
$script:ballFromX = 0.0
$script:ballToX = 0.0
$script:ballT = 0.0
$script:fetchHome = 0.0
$script:audioOk = $false
$script:musicUp = 0
$script:musicQuiet = 0
$script:beatAvg = 0.12
$script:leadMalik = $false
$script:slackAlertFile = Join-Path $script:dir "slack_alert.txt"
$script:slackAlertSize = -1

function Set-Frame([string]$name) {
    $key = "$name`_$($script:facing)"
    if ($script:FRAMES.ContainsKey($key)) { $script:img.Source = $script:FRAMES[$key] }
}

function Enter-State([string]$s, [int]$ticks) {
    if ($script:inHouse -and $s -ne "sleephome") {
        # coming out of the doghouse: light OFF, restart the clocks
        $script:inHouse = $false
        $script:awayTicks = 0
        $script:flyTicks = 0
        try {
            Set-HouseLight $false
            $script:win.Left = Get-DoorX
        } catch {}
        Play-Bark
    }
    $script:state = $s
    $script:stateTicks = $ticks
    $script:rot.Angle = 0
    if ($s -eq "jump") { $script:jumpTick = 0 }
    if ($s -ne "drop" -and $s -ne "jump" -and $s -notlike "fly*") { $script:win.Top = $script:groundY }
    if ($s -notlike "fetch*") {
        try { if ($script:ballWin -and $script:ballWin.IsVisible) { $script:ballWin.Hide() } } catch {}
    }
    if ($s -eq "sleep") { Say "Zzz... 😴" 30 }
    if ($s -eq "sleephome") {
        # inside: light ON, bone + water snack (+2 XP)
        $script:inHouse = $true
        $script:awayTicks = 0
        $script:flyTicks = 0
        $script:win.Left = -20000
        try { Set-HouseLight $true } catch {}
        $script:xp += 2
        Save-Memory
        Say (TR "💡 Light on! Nom nom... bone & water! 🦴💧 (+2 XP = $($script:xp))`nZzz... 🏠😴" "💡 Light on! Nom nom... bone aur paani! 🦴💧 (+2 XP = $($script:xp))`nZzz... 🏠😴") 45
    }
}

function Pick-NextState {
    if (-not $script:roam) { Enter-State "idle" 40; return }
    $r = $script:rand.Next(100)
    if ($r -lt 45) {
        $min = [int]$script:area.Left; $max = [int]($script:area.Right - $script:PW)
        $script:targetX = $script:rand.Next($min, [Math]::Max($min + 1, $max))
        Enter-State "walk" 999
    }
    elseif ($r -lt 65) { Enter-State "idle" (30 + $script:rand.Next(40)) }
    elseif ($r -lt 80) { Enter-State "wag" (20 + $script:rand.Next(20)) }
    elseif ($r -lt 92) { Enter-State "sit" (40 + $script:rand.Next(60)) }
    elseif ($r -lt 96) { Enter-State "gohome" 999 }
    elseif ($r -lt 98 -and $script:learned -contains "dig") { Enter-State "dig" 50 }
    elseif ($r -lt 99 -and $script:learned -contains "zoomies") {
        $script:targetX = $script:area.Left + 10
        Enter-State "zoomies" 60
    }
    else { Play-Bark; Say (Pick-Bark) 20; Enter-State "idle" 20 }
}

function Get-CursorXY {
    $p = [System.Windows.Forms.Cursor]::Position
    $sx = 1.0; $sy = 1.0
    try {
        $d = [Windows.Media.VisualTreeHelper]::GetDpi($script:win)
        $sx = $d.DpiScaleX; $sy = $d.DpiScaleY
    } catch {}
    return @(($p.X / $sx), ($p.Y / $sy))
}

function Do-Tick {
    $script:tick++
    if ($script:hidden) { return }
    if ($script:bubbleTicks -gt 0) {
        $script:bubbleTicks--
        if ($script:bubbleTicks -le 0 -and $script:bub.IsVisible) { $script:bub.Hide() }
    }
    Move-Bubble
    if ($script:paused) { return }

    # dictation: append recognized speech to the live transcript
    if ($script:transcribing) {
        $dc = $null
        while ([KaaluDictation]::Queue.TryDequeue([ref]$dc)) {
            if ($dc) { [void]$script:transcriptSB.Append($dc + " ") }
        }
        try { $script:transEditBox.Text = $script:transcriptSB.ToString() } catch {}
    }

    # voice commands: drain queue, obey the most recent one
    # (discard anything heard while Kaalu himself is talking or dictating)
    if ($script:voiceOn -and -not $script:transcribing) {
        $vc = $null; $vlast = $null
        while ([KaaluVoice]::Queue.TryDequeue([ref]$vc)) { $vlast = $vc }
        $talking = $false
        try { if ($script:tts -and $script:tts.State -ne 'Ready') { $talking = $true } } catch {}
        if ($vlast -and -not $talking) {
            Say "🎙 »$vlast«" 12 $true
            Obey-Command $vlast
        }
    }

    # routines: every ~2.5 min Super Kaalu flies for 10s then returns home;
    # every ~3 min (if no flight happened) he walks home for bone + water
    if (-not $script:inHouse -and $script:state -notlike "fly*" -and $script:state -ne "gohome" -and $script:roam) {
        $script:awayTicks++
        $script:flyTicks++
        if ($script:flyTicks -ge 1500 -and ($script:state -in @("idle", "wag", "walk", "sit"))) {
            Start-Flight
        }
        elseif ($script:awayTicks -ge 1800 -and ($script:state -in @("idle", "wag", "walk", "sit"))) {
            Say (TR "Break time - heading home! 🏠" "Break ka time - ghar chala! 🏠") 25
            Enter-State "gohome" 999
        }
    }

    # auto-feeder: a treat every ~10 minutes (waits for a calm moment)
    $script:treatTicks++
    if ($script:treatTicks -ge 6000 -and ($script:state -in @("idle", "wag", "walk", "sit", "sleephome"))) {
        if (((Get-Date) - $script:treatTime).TotalSeconds -ge 20) {
            $script:treatTicks = 0
            Give-Treat $true
        }
    }

    # Slack ticket alert: a scheduler appends to slack_alert.txt; Kaalu barks
    if (($script:tick % 10) -eq 0) {
        try {
            if (Test-Path $script:slackAlertFile) {
                $len = (Get-Item $script:slackAlertFile).Length
                if ($script:slackAlertSize -lt 0) {
                    $script:slackAlertSize = $len
                } elseif ($len -gt $script:slackAlertSize) {
                    $script:slackAlertSize = $len
                    Play-Bark
                    $script:win.Topmost = $true
                    Enter-State "jump" 10
                    Say (TR "Zee Maalik! Dekhlo, ticket aaya hoga! 🎟" "Zee Maalik! Dekhlo, ticket aaya hoga! 🎟" "Zee Maalik ho! Dekhlo, ticket aail hoga! 🎟") 90
                }
            }
        } catch {}
    }

    # music auto-dance: groove whenever sound is playing on the speakers
    # (self-inits audio; wakes him even from the doghouse; forgiving counter)
    if ($script:musicOn -and $script:state -notlike "fly*" -and $script:state -ne "gohome" -and $script:state -ne "musicdance") {
        if (($script:tick % 3) -eq 0) {
            $mp = 0.0
            try { $mp = [KaaluAudio]::Peak() } catch {}
            if ($mp -gt 0.06) { $script:musicUp++ } else { $script:musicUp = [Math]::Max(0, $script:musicUp - 2) }
            if ($script:musicUp -ge 5 -and ($script:state -in @("idle", "wag", "walk", "sit", "sleephome"))) {
                $script:musicUp = 0; $script:musicQuiet = 0; $script:beatAvg = 0.12
                Say (TR "Music! Let's dance! 🎶💃" "Gaana baja! Chalo naachein! 🎶💃" "Gaana baajal! Chala naachein! 🎶💃") 25
                Enter-State "musicdance" 999
            }
        }
    }

    switch ($script:state) {
        "idle" {
            Set-Frame $(if (($script:tick % 8) -lt 4) { "idle1" } else { "idle2" })
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Pick-NextState }
        }
        "wag" {
            Set-Frame $(if (($script:tick % 4) -lt 2) { "idle1" } else { "idle2" })
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Pick-NextState }
        }
        "walk" {
            $dx = $script:targetX - $script:win.Left
            if ([Math]::Abs($dx) -le 6) { Pick-NextState; return }
            $script:facing = $(if ($dx -gt 0) { "R" } else { "L" })
            $script:win.Left += $(if ($dx -gt 0) { 6 } else { -6 })
            Set-Frame $(if (($script:tick % 4) -lt 2) { "runA" } else { "runB" })
        }
        "sit" {
            Set-Frame "sit"
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Pick-NextState }
        }
        "sleep" {
            Set-Frame $(if (($script:tick % 12) -lt 6) { "sleep1" } else { "sleep2" })
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Enter-State "idle" 30 }
        }
        "chase" {
            $c = Get-CursorXY
            $cx = $c[0] - ($script:PW / 2)
            $dx = $cx - $script:win.Left
            if ([Math]::Abs($dx) -gt 12) {
                $script:facing = $(if ($dx -gt 0) { "R" } else { "L" })
                $script:win.Left += $(if ($dx -gt 0) { 9 } else { -9 })
                Set-Frame $(if (($script:tick % 4) -lt 2) { "runA" } else { "runB" })
            } else {
                Set-Frame "happy"
            }
            $script:stateTicks--
            if ($script:stateTicks -le 0) {
                Play-Bark; Say (TR "Got you! 🐾" "Pakad liya! 🐾") 25; Enter-State "idle" 30
            }
        }
        "spin" {
            $script:facing = $(if (($script:tick % 4) -lt 2) { "R" } else { "L" })
            Set-Frame "runA"
            $script:stateTicks--
            if ($script:stateTicks -le 0) {
                $script:facing = "R"; Say "@_@ Whoa!" 20; Enter-State "idle" 25
            }
        }
        "jump" {
            $script:jumpTick++
            $t = $script:jumpTick
            $h = [Math]::Sin(($t / 10.0) * [Math]::PI) * 60
            $script:win.Top = $script:groundY - $h
            Set-Frame "happy"
            if ($t -ge 10) {
                $script:win.Top = $script:groundY; $script:jumpTick = 0
                Enter-State "idle" 20
            }
        }
        "drop" {
            $script:win.Top += 16
            Set-Frame "runA"
            if ($script:win.Top -ge $script:groundY) {
                $script:win.Top = $script:groundY
                Play-Bark; Say "Oof! 🐾" 15
                Enter-State "idle" 20
            }
        }
        "bark" {
            Set-Frame "bark"
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Enter-State "idle" 20 }
        }
        "shake" {
            Set-Frame $(if (($script:tick % 6) -lt 3) { "sit" } else { "sitpaw" })
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Play-Bark; Enter-State "idle" 25 }
        }
        "rollover" {
            $script:stateTicks--
            $done = 20 - $script:stateTicks
            $dir = $(if ($script:facing -eq "R") { 1 } else { -1 })
            $script:rot.Angle = $dir * ($done / 20.0) * 360
            $script:win.Left += $dir * 5
            Set-Frame "runB"
            if ($script:stateTicks -le 0) {
                $script:rot.Angle = 0
                Play-Bark; Say "Ta-da! 🔄" 20; Enter-State "idle" 25
            }
        }
        "playdead" {
            Set-Frame "dead"
            $script:stateTicks--
            if ($script:stateTicks -le 0) {
                Say (TR "Just kidding! 😜" "Mazaak tha! 😜") 20; Play-Bark; Enter-State "jump" 10
            }
        }
        "dance" {
            $script:facing = $(if (($script:tick % 6) -lt 3) { "R" } else { "L" })
            $script:rot.Angle = [Math]::Sin($script:tick * 0.8) * 14
            $script:win.Top = $script:groundY - [Math]::Abs([Math]::Sin($script:tick * 0.5)) * 22
            Set-Frame $(if (($script:tick % 4) -lt 2) { "runA" } else { "runB" })
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Say "Ta-da! 💃" 20; Enter-State "idle" 25 }
        }
        "howl" {
            Set-Frame "bark"
            $script:rot.Angle = $(if ($script:facing -eq "R") { -22 } else { 22 })
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Enter-State "idle" 25 }
        }
        "fetchthrow" {
            $script:ballT += (1.0 / 14)
            $t = [Math]::Min(1.0, $script:ballT)
            $bx = $script:ballFromX + ($script:ballToX - $script:ballFromX) * $t
            $by = ($script:area.Bottom - 30) - [Math]::Sin([Math]::PI * $t) * 220
            $script:ballWin.Left = $bx
            $script:ballWin.Top = $by
            $script:facing = $(if ($script:ballToX -gt $script:win.Left) { "R" } else { "L" })
            Set-Frame "happy"
            if ($t -ge 1.0) { Enter-State "fetchchase" 999 }
        }
        "fetchchase" {
            $dx = ($script:ballToX - $script:PW / 2) - $script:win.Left
            if ([Math]::Abs($dx) -gt 20) {
                $script:facing = $(if ($dx -gt 0) { "R" } else { "L" })
                $script:win.Left += $(if ($dx -gt 0) { 10 } else { -10 })
                Set-Frame $(if (($script:tick % 4) -lt 2) { "runA" } else { "runB" })
            } else {
                $script:ballWin.Hide()
                Enter-State "fetchback" 999
            }
        }
        "fetchback" {
            $dx = $script:fetchHome - $script:win.Left
            if ([Math]::Abs($dx) -gt 12) {
                $script:facing = $(if ($dx -gt 0) { "R" } else { "L" })
                $script:win.Left += $(if ($dx -gt 0) { 8 } else { -8 })
                Set-Frame $(if (($script:tick % 4) -lt 2) { "runA" } else { "runB" })
            } else {
                Play-Bark
                Say (TR "Got it! 🎾 Throw again?" "Le aaya! 🎾 Phir se phenko?") 30
                Enter-State "idle" 30
            }
        }
        "dig" {
            Set-Frame $(if (($script:tick % 4) -lt 2) { "dig1" } else { "dig2" })
            $script:stateTicks--
            if ($script:stateTicks -le 0) {
                $r = $script:rand.Next(100)
                if ($r -lt 40) {
                    $script:xp += 5
                    Save-Memory
                    Play-Bark
                    Say (TR "🦴 Found a buried bone! (+5 XP = $($script:xp))" "🦴 Zameen se bone mil gaya! (+5 XP = $($script:xp))") 40
                    Enter-State "jump" 10
                } elseif ($r -lt 70) {
                    Say (TR "🧦 Found an old sock... yuck!" "🧦 Ek purana moza mila... chhee!") 30
                    Enter-State "idle" 25
                } else {
                    Say (TR "Nothing here... next time! 😕" "Kuch nahi mila... agli baar pakka! 😕") 30
                    Enter-State "idle" 25
                }
            }
        }
        "zoomies" {
            $dx = $script:targetX - $script:win.Left
            if ([Math]::Abs($dx) -le 14) {
                $mid = ($script:area.Left + $script:area.Right) / 2
                $script:targetX = $(if ($script:win.Left -gt $mid) { $script:area.Left + 10 } else { $script:area.Right - $script:PW - 10 })
            } else {
                $script:facing = $(if ($dx -gt 0) { "R" } else { "L" })
                $script:win.Left += $(if ($dx -gt 0) { 14 } else { -14 })
            }
            Set-Frame $(if (($script:tick % 2) -eq 0) { "runA" } else { "runB" })
            $script:stateTicks--
            if ($script:stateTicks -le 0) {
                Say (TR "*pant pant* That was FUN! 💨" "*haanf haanf* Maza aa gaya! 💨") 25
                Enter-State "sit" 40
            }
        }
        "gohome" {
            $doorX = Get-DoorX
            $dx = $doorX - $script:win.Left
            if ([Math]::Abs($dx) -le 8) {
                Enter-State "sleephome" (300 + $script:rand.Next(400))
            } else {
                $script:facing = $(if ($dx -gt 0) { "R" } else { "L" })
                $script:win.Left += $(if ($dx -gt 0) { 6 } else { -6 })
                Set-Frame $(if (($script:tick % 4) -lt 2) { "runA" } else { "runB" })
            }
        }
        "sleephome" {
            if (($script:tick % 120) -eq 0) { Say "Zzz... 😴" 20 $true }
            $script:stateTicks--
            if ($script:stateTicks -le 0) { Enter-State "idle" 30 }
        }
        "musicdance" {
            $mp = 0.0
            try { $mp = [KaaluAudio]::Peak() } catch {}
            $script:beatAvg = $script:beatAvg * 0.85 + $mp * 0.15
            $intensity = [Math]::Min(1.0, $mp * 3.5)
            $isBeat = ($mp -gt ($script:beatAvg * 1.35 + 0.03))
            $hop = 8 + ($intensity * 26)
            if ($isBeat) {
                $hop += 20
                $script:facing = $(if ($script:facing -eq "R") { "L" } else { "R" })
            }
            $script:rot.Angle = [Math]::Sin($script:tick * 0.9) * (6 + $intensity * 16)
            $script:win.Top = $script:groundY - [Math]::Abs([Math]::Sin($script:tick * 0.7)) * $hop
            Set-Frame $(if (($script:tick % 4) -lt 2) { "runA" } else { "runB" })
            if ($mp -gt 0.05) { $script:musicQuiet = 0 } else { $script:musicQuiet++ }
            if ($script:musicQuiet -ge 25 -or -not $script:musicOn) {
                $script:win.Top = $script:groundY
                Say (TR "That was fun! 🎶" "Maza aa gaya! 🎶" "Maza aa gail ho! 🎶") 20
                Enter-State "idle" 30
            }
        }
        "flyout" {
            $dx = $script:flyTX - $script:win.Left
            $dy = $script:flyTY - $script:win.Top
            if (([Math]::Abs($dx) -lt 24) -and ([Math]::Abs($dy) -lt 24)) {
                $script:flyTX = $script:area.Left + $script:rand.Next([int][Math]::Max(1, $script:area.Width - $script:PW))
                $script:flyTY = $script:area.Top + 20 + $script:rand.Next([int][Math]::Max(60, $script:groundY - $script:area.Top - 40))
            } else {
                if ($dx -ne 0) { $script:facing = $(if ($dx -gt 0) { "R" } else { "L" }) }
                $script:win.Left += [Math]::Max(-12, [Math]::Min(12, $dx))
                $script:win.Top += ([Math]::Max(-10, [Math]::Min(10, $dy)) + [Math]::Sin($script:tick * 0.5) * 2)
            }
            if ($script:win.Top -lt $script:area.Top) { $script:win.Top = $script:area.Top }
            if ($script:win.Top -gt $script:groundY) { $script:win.Top = $script:groundY }
            Set-Frame $(if (($script:tick % 4) -lt 2) { "fly1" } else { "fly2" })
            $script:stateTicks--
            if ($script:stateTicks -le 0) {
                Say (TR "Patrol done - flying home! 🦇🏠" "Patrol poora - ghar wapas udaan! 🦇🏠") 25
                Enter-State "flyhome" 999
            }
        }
        "flyhome" {
            $tx = Get-DoorX
            $dx = $tx - $script:win.Left
            $dy = $script:groundY - $script:win.Top
            if (([Math]::Abs($dx) -lt 10) -and ([Math]::Abs($dy) -lt 10)) {
                $script:win.Top = $script:groundY
                Say (TR "Landed! Mask & cape off 🦇" "Landing! Mask aur cape utaar di 🦇") 20
                Enter-State "sleephome" (200 + $script:rand.Next(200))
            } else {
                if ($dx -ne 0) { $script:facing = $(if ($dx -gt 0) { "R" } else { "L" }) }
                $script:win.Left += [Math]::Max(-12, [Math]::Min(12, $dx))
                $script:win.Top += [Math]::Max(-10, [Math]::Min(10, $dy))
                Set-Frame $(if (($script:tick % 4) -lt 2) { "fly1" } else { "fly2" })
            }
        }
    }

    # clamp to screen (not while sleeping inside the house)
    if (-not $script:inHouse) {
        if ($script:win.Left -lt $script:area.Left) { $script:win.Left = $script:area.Left }
        if ($script:win.Left -gt $script:area.Right - $script:PW) { $script:win.Left = $script:area.Right - $script:PW }
    }
    $script:leadMalik = $false
}

function Do-Bark {
    Play-Bark
    Say (Pick-Bark) 20
    Enter-State "bark" 6
}

# ------------------------------------------------------------
# System actions
# ------------------------------------------------------------
function Flush-UI {
    try { $script:win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render) } catch {}
}

function Volume-Change([string]$dir) {
    $vk = [byte]$(if ($dir -eq "up") { 0xAF } else { 0xAE })
    for ($i = 0; $i -lt 5; $i++) { Send-VKey $vk }
    Say $(if ($dir -eq "up") { TR "Volume up! 🔊" "Awaaz badha di! 🔊" } else { TR "Volume down! 🔉" "Awaaz kam kar di! 🔉" }) 20
}

function Volume-Mute {
    Send-VKey ([byte]0xAD)
    $script:muted = -not $script:muted
    Say $(if ($script:muted) { TR "Muted! 🔇" "Chup! Mute kar diya 🔇" } else { TR "Sound's back! 🔊" "Awaaz wapas aa gayi! 🔊" }) 20
}

function Set-Brightness([int]$val) {
    Say (TR "Adjusting brightness... 🔆" "Brightness badal raha hoon... 🔆") 40; Flush-UI
    try {
        $m = Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop
        $m | Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]1; Brightness = [byte]$val } -ErrorAction Stop | Out-Null
        Say (TR "Brightness set to $val% 🔆" "Brightness $val% kar di! 🔆") 25
    } catch {
        Say (TR "Your monitor won't let me change brightness, woof 😕" "Ye monitor brightness badalne nahi deta, bhow 😕") 30
    }
}

function Nudge-Brightness([int]$delta) {
    try {
        $cur = (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop).CurrentBrightness
        $new = [Math]::Max(0, [Math]::Min(100, [int]$cur + $delta))
        Set-Brightness $new
    } catch {
        Say "Your monitor won't let me change brightness, woof 😕" 30
    }
}

function Show-Stats {
    Say (TR "Sniffing your system... 🐽" "System soongh raha hoon... 🐽") 60; Flush-UI
    $lines = @()
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) {
            $chg = $(if ($bat.BatteryStatus -eq 2) { " (charging ⚡)" } else { "" })
            $lines += "🔋 Battery: $($bat.EstimatedChargeRemaining)%$chg"
        } else { $lines += "🔌 On wall power (no battery)" }
    } catch {}
    try {
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $lines += "🧠 CPU: $([int]$cpu)%"
    } catch {}
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $ram = [int](100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100))
        $lines += "🐏 RAM: $ram% used"
    } catch {}
    try {
        $d = Get-PSDrive C -ErrorAction Stop
        $freeGB = [Math]::Round($d.Free / 1GB, 1)
        $lines += "💾 Disk C: $freeGB GB free"
    } catch {}
    try {
        $cur = (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop).CurrentBrightness
        $lines += "🔆 Brightness: $cur%"
    } catch {}
    $lines += "🕐 $(Get-Date -Format 'hh:mm tt, ddd dd MMM')"
    Say ($lines -join "`n") 80
}

function Launch-App([string]$cmd, [string]$nice) {
    try { Start-Process $cmd -ErrorAction Stop; Say (TR "Opening $nice! 🚀" "$nice khol raha hoon! 🚀") 20 }
    catch { Say (TR "Couldn't find $nice on this computer 😕" "$nice is computer par nahi mila 😕") 25 }
}

function Launch-Website {
    $u = [Microsoft.VisualBasic.Interaction]::InputBox("Where to, boss? (e.g. google.com)", "Kaalu - open website", "")
    if ($u -and $u.Trim()) {
        $u = $u.Trim()
        if ($u -notmatch '^https?://') { $u = "https://$u" }
        try { Start-Process $u; Say (TR "Fetching that page! 🌐" "Page la raha hoon! 🌐") 20 } catch { Say (TR "Hmm, that URL confused me 😕" "Hmm, ye URL samajh nahi aaya 😕") 20 }
    }
}

# ------------------------------------------------------------
# App launcher: everything in the Start Menu
# ------------------------------------------------------------
$script:APPS = @()
$script:FILES = @()
$script:INDEX = @()

function Load-Apps {
    try { $script:APPS = @(Get-StartApps | Sort-Object Name) } catch { $script:APPS = @() }
}

function Load-Files {
    $items = New-Object System.Collections.Generic.List[object]
    $known = @(
        @{ n = "Desktop";   p = [Environment]::GetFolderPath('Desktop') },
        @{ n = "Documents"; p = [Environment]::GetFolderPath('MyDocuments') },
        @{ n = "Downloads"; p = (Join-Path $env:USERPROFILE 'Downloads') },
        @{ n = "Pictures";  p = [Environment]::GetFolderPath('MyPictures') },
        @{ n = "Music";     p = [Environment]::GetFolderPath('MyMusic') },
        @{ n = "Videos";    p = (Join-Path $env:USERPROFILE 'Videos') },
        @{ n = "C drive";   p = 'C:\' },
        @{ n = "Recycle Bin"; p = 'shell:RecycleBinFolder' }
    )
    foreach ($k in $known) {
        try {
            if ($k.p -like 'shell:*' -or (Test-Path $k.p)) {
                $items.Add([pscustomobject]@{ Name = $k.n; Kind = "folder"; Target = $k.p; Disp = "📁 $($k.n)" })
            }
        } catch {}
    }
    foreach ($root in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:USERPROFILE 'Downloads'))) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        try {
            Get-ChildItem $root -ErrorAction SilentlyContinue | Select-Object -First 150 | ForEach-Object {
                if ($_.PSIsContainer) {
                    $items.Add([pscustomobject]@{ Name = $_.Name; Kind = "folder"; Target = $_.FullName; Disp = "📁 $($_.Name)" })
                } else {
                    $nm = [IO.Path]::GetFileNameWithoutExtension($_.Name)
                    if ($nm) {
                        $items.Add([pscustomobject]@{ Name = $nm; Kind = "file"; Target = $_.FullName; Disp = "📄 $($_.Name)" })
                    }
                }
            }
        } catch {}
    }
    $script:FILES = @($items | Sort-Object Name)
}

function Rebuild-Index {
    $ix = New-Object System.Collections.Generic.List[object]
    foreach ($a in $script:APPS) {
        $ix.Add([pscustomobject]@{ Name = $a.Name; Kind = "app"; Target = $a.AppID; Disp = "🚀 $($a.Name)" })
    }
    foreach ($f in $script:FILES) { $ix.Add($f) }
    $script:INDEX = @($ix)
}

function Ensure-Index {
    if (@($script:INDEX).Count -eq 0) {
        if (@($script:APPS).Count -eq 0) { Load-Apps }
        Load-Files
        Rebuild-Index
    }
}

function Launch-Entry($e) {
    try {
        if ($e.Kind -eq "app") { Start-Process "explorer.exe" "shell:AppsFolder\$($e.Target)" }
        elseif ($e.Kind -eq "folder") { Start-Process "explorer.exe" "`"$($e.Target)`"" }
        else { Start-Process -FilePath $e.Target }
        Say (TR "Opening $($e.Name)! 🚀" "$($e.Name) khol raha hoon! 🚀") 20
    } catch {
        Say (TR "Couldn't open $($e.Name) 😕" "$($e.Name) nahi khula 😕") 20
    }
}

function Launch-AppEntry($app) {
    try {
        Start-Process "explorer.exe" "shell:AppsFolder\$($app.AppID)"
        Say (TR "Opening $($app.Name)! 🚀" "$($app.Name) khol raha hoon! 🚀") 20
    } catch {
        Say (TR "Couldn't open $($app.Name) 😕" "$($app.Name) nahi khula 😕") 20
    }
}

function Launch-ByName([string]$q) {
    Ensure-Index
    $q = "$q".Trim()
    if (-not $q) { Show-AppPicker ""; return }
    $ql = $q.ToLower()
    $exact = @($script:INDEX | Where-Object { "$($_.Name)".ToLower() -eq $ql })
    if ($exact.Count -ge 1) { Launch-Entry $exact[0]; return }
    $starts = @($script:INDEX | Where-Object { $_.Name -ilike "$q*" })
    if ($starts.Count -eq 1) { Launch-Entry $starts[0]; return }
    $contains = @($script:INDEX | Where-Object { $_.Name -ilike "*$q*" })
    if ($contains.Count -eq 1) { Launch-Entry $contains[0]; return }
    if ($contains.Count -eq 0) {
        # normalized match: ignore spaces/underscores/dots (helps voice results)
        $qn = ($ql -replace '[^a-z0-9]', '')
        if ($qn) {
            $norm = @($script:INDEX | Where-Object { ("$($_.Name)".ToLower() -replace '[^a-z0-9]', '') -like "*$qn*" })
            if ($norm.Count -ge 1) { Launch-Entry $norm[0]; return }
        }
    }
    if ($starts.Count -gt 1 -or $contains.Count -gt 1) { Show-AppPicker $q; return }
    Say (TR "Can't sniff out '$q' 🥺 Here's everything I've got:" "'$q' nahi mila 🥺 Ye sab hai mere paas:") 25
    Show-AppPicker ""
}

# --- picker window ---
$script:pick = New-Object Windows.Window
$script:pick.Title = "Kaalu Launcher"
$script:pick.Width = 340
$script:pick.Height = 430
$script:pick.WindowStyle = "None"
$script:pick.ResizeMode = "NoResize"
$script:pick.Topmost = $true
$script:pick.ShowInTaskbar = $false
$script:pick.ShowActivated = $true

$pickRoot = New-Object Windows.Controls.Border
$pickRoot.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(28,28,34))
$pickRoot.BorderBrush = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(229,72,77))
$pickRoot.BorderThickness = "2"
$pickDock = New-Object Windows.Controls.DockPanel
$pickDock.Margin = "10"
$pickRoot.Child = $pickDock
$script:pick.Content = $pickRoot

$script:pickBox = New-Object Windows.Controls.TextBox
$script:pickBox.FontSize = 15
$script:pickBox.Margin = "0,0,0,8"
[Windows.Controls.DockPanel]::SetDock($script:pickBox, "Top")
$pickDock.Children.Add($script:pickBox) | Out-Null

$pickHint = New-Object Windows.Controls.TextBlock
$pickHint.Text = "type to search  |  Enter = launch  |  Esc = close"
$pickHint.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(150,150,160))
$pickHint.FontSize = 11
$pickHint.Margin = "0,6,0,0"
[Windows.Controls.DockPanel]::SetDock($pickHint, "Bottom")
$pickDock.Children.Add($pickHint) | Out-Null

$script:pickList = New-Object Windows.Controls.ListBox
$script:pickList.DisplayMemberPath = "Disp"
$script:pickList.FontSize = 13
$pickDock.Children.Add($script:pickList) | Out-Null

function Update-PickList {
    $q = $script:pickBox.Text.Trim()
    $items = $script:INDEX
    if ($q) { $items = @($script:INDEX | Where-Object { $_.Name -ilike "*$q*" -or $_.Disp -ilike "*$q*" }) }
    $script:pickList.ItemsSource = $items
    if (@($items).Count -gt 0) { $script:pickList.SelectedIndex = 0 }
}

function Invoke-PickSelection {
    $sel = $script:pickList.SelectedItem
    if (-not $sel -and $script:pickList.Items.Count -gt 0) { $sel = $script:pickList.Items[0] }
    if ($sel) {
        $script:pick.Hide()
        Launch-Entry $sel
    }
}

$script:pickBox.Add_TextChanged({ Update-PickList })
$script:pickBox.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq "Return") { Invoke-PickSelection; $e.Handled = $true }
    elseif ($e.Key -eq "Escape") { $script:pick.Hide(); $e.Handled = $true }
    elseif ($e.Key -eq "Down") {
        if ($script:pickList.SelectedIndex -lt $script:pickList.Items.Count - 1) { $script:pickList.SelectedIndex++ }
        $e.Handled = $true
    }
    elseif ($e.Key -eq "Up") {
        if ($script:pickList.SelectedIndex -gt 0) { $script:pickList.SelectedIndex-- }
        $e.Handled = $true
    }
})
$script:pickList.Add_MouseDoubleClick({ Invoke-PickSelection })
$script:pick.Add_Closing({ param($s, $e) $e.Cancel = $true; $script:pick.Hide() })

function Show-AppPicker([string]$query) {
    Ensure-Index
    $script:pickBox.Text = $query
    Update-PickList
    $px = $script:win.Left + $script:PW + 6
    if ($px + 340 -gt $script:area.Right) { $px = $script:win.Left - 346 }
    if ($px -lt $script:area.Left) { $px = $script:area.Left }
    $py = $script:groundY + $script:PH - 430
    if ($py -lt $script:area.Top) { $py = $script:area.Top }
    $script:pick.Left = $px
    $script:pick.Top = $py
    $script:pick.Show()
    $script:pick.Activate() | Out-Null
    $script:pickBox.Focus() | Out-Null
    $script:pickBox.SelectAll()
}

# ------------------------------------------------------------
# Slack: huddle calls, DMs, answer
# ------------------------------------------------------------
$script:slackCfgFile = Join-Path $script:dir "slack_config.json"
$script:slackContacts = @()
if (Test-Path $script:slackCfgFile) {
    try {
        $sc = Get-Content $script:slackCfgFile -Raw | ConvertFrom-Json
        $script:slackContacts = @($sc.contacts)
    } catch {}
}

function Focus-Slack {
    $p = Get-Process slack -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) {
        [KaaluWin]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
        [KaaluWin]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
        return $true
    }
    try { Start-Process "slack://open" } catch {}
    return $false
}

function Find-SlackContact([string]$q) {
    $ql = "$q".Trim().ToLower()
    if (-not $ql) { return $null }
    foreach ($c in $script:slackContacts) {
        if ("$($c.name)".ToLower() -eq $ql -or "$($c.full)".ToLower() -eq $ql) { return $c }
    }
    foreach ($c in $script:slackContacts) {
        if ("$($c.name)".ToLower() -like "*$ql*" -or "$($c.full)".ToLower() -like "*$ql*" -or $ql -like "*$("$($c.name)".ToLower())*") { return $c }
    }
    return $null
}

function Open-SlackDM([string]$who) {
    $c = Find-SlackContact $who
    if (-not $c) {
        Say (TR "I don't know '$who' on Slack yet 😕`n(add them to slack_config.json)" "'$who' ko Slack par nahi jaanta 😕`n(slack_config.json mein add karo)") 35
        return $null
    }
    try { Start-Process "https://slack.com/app_redirect?channel=$($c.id)" } catch {}
    Say (TR "Opening chat with $($c.full) 💬" "$($c.full) ki chat khol raha hoon 💬") 25
    return $c
}

function Call-SlackContact([string]$who) {
    $c = Find-SlackContact $who
    if (-not $c) {
        Say (TR "I don't know '$who' on Slack yet 😕" "'$who' ko Slack par nahi jaanta 😕") 30
        return
    }
    Say (TR "📞 Calling $($c.full) on Slack..." "📞 $($c.full) ko Slack par call laga raha hoon...") 45
    try { Start-Process "https://slack.com/app_redirect?channel=$($c.id)" } catch {}
    $ht = New-Object Windows.Threading.DispatcherTimer
    $ht.Interval = [TimeSpan]::FromSeconds(3.5)
    $ht.Add_Tick({
        $this.Stop()
        if (Focus-Slack) {
            Start-Sleep -Milliseconds 800
            try { [System.Windows.Forms.SendKeys]::SendWait("^+h") } catch {}
            Say (TR "📞 Huddle started - ring ring!" "📞 Huddle shuru - ring ring!") 30
        } else {
            Say (TR "Slack is still starting - say it again in a moment!" "Slack abhi khul raha hai - thodi der mein phir bolo!") 30
        }
    })
    $ht.Start()
}

function Answer-SlackCall {
    $was = Focus-Slack
    if ($was) {
        Start-Sleep -Milliseconds 700
        try { [System.Windows.Forms.SendKeys]::SendWait("^+h") } catch {}
        Say (TR "📞 Joining the huddle!" "📞 Huddle join kar raha hoon!") 30
    } else {
        Say (TR "Slack wasn't running - starting it! 💬" "Slack chalu nahi tha - khol raha hoon! 💬") 30
    }
}

# ------------------------------------------------------------
# NouTube (media player) - open, focus, playback controls
# ------------------------------------------------------------
$script:nouAppId = "NonbiliInc.NouTube_g8kw1c07ts5dt!NonbiliInc.NouTube"

function Open-NouTube {
    $p = Get-Process noutube -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) {
        [KaaluWin]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
        [KaaluWin]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
        Say (TR "NouTube is up! 🎵" "NouTube saamne! 🎵" "NouTube saamne ba! 🎵") 20
    } else {
        try { Start-Process "explorer.exe" "shell:AppsFolder\$script:nouAppId" } catch {}
        Say (TR "Opening NouTube! 🎵" "NouTube khol raha hoon! 🎵" "NouTube khol tani ho! 🎵") 20
    }
}

function Media-Key([string]$what) {
    switch ($what) {
        "playpause" { Send-VKey ([byte]0xB3); Say (TR "Play / Pause ⏯" "Play / Pause ⏯" "Play / Pause ⏯") 15 }
        "next"      { Send-VKey ([byte]0xB0); Say (TR "Next! ⏭" "Agla gaana! ⏭" "Agla gaana ho! ⏭") 15 }
        "prev"      { Send-VKey ([byte]0xB1); Say (TR "Previous! ⏮" "Pichhla gaana! ⏮" "Pichhla gaana ho! ⏮") 15 }
    }
}

# --- timers & reminders ---
$script:timerCount = 0

function Start-KTimer([double]$minutes, [string]$label) {
    if ($minutes -le 0) { return }
    $script:timerCount++
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMinutes($minutes)
    $msg = $(if ($label) { $label } else { "$minutes minute timer" })
    $t.Add_Tick({
        $this.Stop()
        Play-Alarm
        $script:win.Topmost = $true
        Enter-State "jump" 10
        Say (TR "⏰ WOOF WOOF! Time's up: $($this.Tag)" "⏰ BHOW BHOW! Time ho gaya: $($this.Tag)") 90
    })
    $t.Tag = $msg
    $t.Start()
    Say (TR "Timer set: $msg ⏰ I'll bark!" "Timer laga diya: $msg ⏰ Main bhonkunga!") 30
}

function Ask-Timer {
    $v = [Microsoft.VisualBasic.Interaction]::InputBox("How many minutes?", "Kaalu - timer", "10")
    $mins = 0.0
    if ([double]::TryParse($v, [ref]$mins)) { Start-KTimer $mins "" }
}

function Ask-Reminder {
    $what = [Microsoft.VisualBasic.Interaction]::InputBox("What should I remind you about?", "Kaalu - reminder", "")
    if (-not $what) { return }
    $v = [Microsoft.VisualBasic.Interaction]::InputBox("In how many minutes?", "Kaalu - reminder", "30")
    $mins = 0.0
    if ([double]::TryParse($v, [ref]$mins)) { Start-KTimer $mins $what }
}

# ------------------------------------------------------------
# Training: treats, teaching, tricks
# ------------------------------------------------------------
function Give-Treat([bool]$auto = $false) {
    $now = Get-Date
    $wait = 20 - ($now - $script:treatTime).TotalSeconds
    if ($wait -gt 0) {
        if (-not $auto) { Say (TR "So full! 🤢 Give me $([int][Math]::Ceiling($wait))s to chew..." "Pet bhar gaya! 🤢 $([int][Math]::Ceiling($wait)) second ruko...") 20 }
        return
    }
    $pre = $(if ($auto) { TR "🍖 Auto-feeder! " "🍖 Auto-feeder! " } else { "" })
    $script:treatTime = $now
    $script:xp += 10
    Save-Memory
    Play-Bark
    Enter-State "jump" 10
    $nt = Next-Trick
    if (-not $nt) {
        Say ($pre + (TR "Nom nom! 🦴 (+10 XP = $($script:xp))`nI know ALL the tricks! 🏆" "Nom nom! Bahut tasty! 🦴 (+10 XP = $($script:xp))`nMujhe SAARI tricks aati hain! 🏆")) 35
    } elseif ($script:xp -ge $nt.xp) {
        Say ($pre + (TR "Nom nom! 🦴 (+10 XP = $($script:xp))`n🎓 I'm ready to learn: $($nt.name) — use 'Teach next trick'!" "Nom nom! 🦴 (+10 XP = $($script:xp))`n🎓 Main $($nt.name) seekhne ke liye ready hoon — 'Teach next trick' dabao!")) 45
    } else {
        Say ($pre + (TR "Nom nom! 🦴 (+10 XP = $($script:xp))`nNext trick at $($nt.xp) XP: $($nt.name)" "Nom nom! 🦴 (+10 XP = $($script:xp))`nAgli trick $($nt.xp) XP par: $($nt.name)")) 35
    }
}

function Teach-Trick {
    $nt = Next-Trick
    if (-not $nt) { Say (TR "I've mastered everything! 🏆 Level $(Get-Level)!" "Sab kuch seekh liya! 🏆 Level $(Get-Level)!") 30; return }
    if ($script:xp -lt $nt.xp) {
        Say (TR "Not ready for $($nt.name) yet! 🥺`nNeed $($nt.xp) XP, have $($script:xp). More treats please! 🦴" "Abhi $($nt.name) ke liye ready nahi! 🥺`n$($nt.xp) XP chahiye, abhi $($script:xp) hai. Aur treats do na! 🦴") 40
        return
    }
    $script:learned = @($script:learned) + $nt.id
    Save-Memory
    Play-Bark
    Enter-State "spin" 16
    Say (TR "🎉 I learned $($nt.name)!`n⭐ Now Level $(Get-Level)!" "🎉 Maine $($nt.name) seekh liya!`n⭐ Ab main Level $(Get-Level) hoon!") 50
}

function Start-Fetch {
    $script:fetchHome = $script:win.Left
    $roomR = ($script:area.Right - $script:PW) - $script:win.Left
    $roomL = $script:win.Left - $script:area.Left
    if ($roomR -ge $roomL) {
        $script:ballToX = $script:win.Left + [Math]::Max(200.0, $roomR * 0.8)
    } else {
        $script:ballToX = $script:win.Left - [Math]::Max(200.0, $roomL * 0.8)
    }
    if ($script:ballToX -lt $script:area.Left) { $script:ballToX = $script:area.Left }
    if ($script:ballToX -gt ($script:area.Right - 30)) { $script:ballToX = $script:area.Right - 30 }
    $script:ballFromX = $script:win.Left + $script:PW / 2
    $script:ballT = 0.0
    $script:ballWin.Left = $script:ballFromX
    $script:ballWin.Top = $script:area.Bottom - 130
    $script:ballWin.Show()
    Say "🎾 Wheee!" 12
    Enter-State "fetchthrow" 999
}

function Do-Trick([string]$id) {
    if ($script:learned -notcontains $id) {
        Say (TR "I haven't learned that yet! 🥺 Train me with treats 🦴" "Ye abhi nahi seekha! 🥺 Treats khila ke sikhao 🦴") 30
        return
    }
    switch ($id) {
        "shake"    { Say (TR "🐾 Hi-five!" "🐾 Haath milao!") 20; Enter-State "shake" 24 }
        "rollover" { Enter-State "rollover" 20 }
        "playdead" { Say (TR "💀 *dramatic gasp*" "💀 Hai! Mar gaya main!") 15; Enter-State "playdead" 30 }
        "dance"    { Say (TR "💃 Dance party!" "💃 Chalo naachte hain!") 25; Enter-State "dance" 40 }
        "howl"     { Play-Howl; Say "Awooooo! 🌙" 30; Enter-State "howl" 25 }
        "fetch"    { Start-Fetch }
        "dig"      { Say (TR "🕳 Digging time!" "🕳 Khudai shuru!") 15; Enter-State "dig" 50 }
        "zoomies"  {
            Say (TR "💨 ZOOMIES!!!" "💨 BHAAGO! Zoomies time!") 15
            $script:targetX = $script:area.Left + 10
            Enter-State "zoomies" 70
        }
    }
}

function Obey-Command([string]$raw) {
    $c = "$raw".Trim().ToLower()
    if ($c.StartsWith("kaalu")) { $c = $c.Substring(5).Trim() }
    if (-not $c) { Play-Bark; Say (TR "Woof? I'm listening 👂" "Bhow? Sun raha hoon 👂") 20; return }
    $script:leadMalik = $true
    switch -Regex ($c) {
        '^answer|utha lo|pick up'      { Answer-SlackCall; return }
        '^(call|huddle)\s+(.+)$'       { Call-SlackContact $Matches[2]; return }
        '^(.+)\s+ko\s+(call|phone)'    { Call-SlackContact $Matches[1]; return }
        '^(message|dm)\s+(.+)$'        { Open-SlackDM $Matches[2] | Out-Null; return }
        '^(open|launch|start)\s+(.+)$' { Launch-ByName $Matches[2]; return }
        '^(.+)\s+(kholo|chalao)$'      { Launch-ByName $Matches[1]; return }
        '^(hello|hey|namaste|pranaam|ram ram|ka ho|kaa ho)' { Play-Bark; Say (TR "Hello boss! 🐾" "Namaste boss! 🙏🐾" "Pranaam malik! 🙏🐾") 25; return }
        'roll|palti'        { Do-Trick "rollover"; return }
        'dead|bang|mar ja'  { Do-Trick "playdead"; return }
        'shake|paw|five|haath' { Do-Trick "shake"; return }
        'music mode|auto dance|dance to music|gaane pe naach' { $script:musicOn = -not $script:musicOn; Save-Memory; if (-not $script:musicOn -and $script:state -eq "musicdance") { Enter-State "idle" 20 }; Say (TR "Music dance toggled! 🎶" "Music dance toggle kiya! 🎶" "Music dance toggle ho! 🎶") 20; return }
        'dance|naach'       { Do-Trick "dance"; return }
        'howl|chillao'      { Do-Trick "howl"; return }
        'fetch|ball|gend'   { Do-Trick "fetch"; return }
        'dig|khodo|khudai'  { Do-Trick "dig"; return }
        'zoomies|bhaag|daudo|daur|^run' { Do-Trick "zoomies"; return }
        'fly|udaan|^udo|^udh|super' { Start-Flight; return }
        'good (boy|dog)|shabash|shabaas|badhiya' { Enter-State "jump" 10; Say (TR "😊 Best day ever!" "😊 Aaj ka din sabse accha!" "😊 Aaj dinwa badhiya ba! ") 25; return }
        'wake|utho|uth ja|jag ja' { Enter-State "idle" 30; Play-Bark; Say (TR "I'm up! 🐶" "Uth gaya! 🐶" "Jaag gaili ho! 🐶") 15; return }
        'sit|baith'         { Say (TR "Sitting! 🐶" "Baith gaya! 🐶" "Baith gaili ho! 🐶") 15; Enter-State "sit" 80; return }
        'speak|bark|talk|bolo|bhonko|bhaunk' { Do-Bark; return }
        'jump|hop|kood|phaand' { Enter-State "jump" 10; return }
        'spin|ghoom|ghum'   { Enter-State "spin" 16; return }
        'sleep|nap|so ja|ghar ja|go home|ghare|sut ja' { Say (TR "Heading to my house! 🏠" "Ghar ja raha hoon! 🏠" "Ghare jaat baani! 🏠") 20; Enter-State "gohome" 999; return }
        'chase|cursor|mouse|chuha|pakdo' { Say (TR "I'll get it! 🐾" "Abhi pakadta hoon! 🐾" "Abhi pakadat baani! 🐾") 15; Enter-State "chase" 150; return }
        'come|here|home|aao|aaja|idhar|aawa|aav' { Say (TR "Coming! 🐾" "Aa raha hoon! 🐾" "Aavat baani ho! 🐾") 15; $script:targetX = ($script:area.Left + $script:area.Right - $script:PW) / 2; Enter-State "walk" 999; return }
        'stop|stay|ruk|thahar' { Say (TR "Staying! 📌" "Yahin rukunga! 📌" "Ihe rukab ho! 📌") 15; Enter-State "idle" 80; return }
        'joke|sunao|hasao'  { Say (Pick-Joke) 60; return }
        'zscaler|vpn'       { Show-Zscaler; return }
        'spell|grammar|check spelling|check this|check text' { Show-SpellCheck ""; return }
        'transcrib|dictat|take notes|note likho|^likho|start writing' { Start-Transcribe; return }
        '^noutube|nou tube|nou music|open nou' { Open-NouTube; return }
        'play ?pause|^pause$|^play$|play music|music play|gaana bajao|bajao gaana' { Media-Key "playpause"; return }
        'next (song|track|video|gaana)|^next$|agla gaana|^skip' { Media-Key "next"; return }
        'previous|pichhla|pichla|prev track' { Media-Key "prev"; return }
        'stat|battery|cpu'  { Show-Stats; return }
        'treat|food|eat|khana|biscuit' { Give-Treat; return }
        default             { Say (TR "*head tilt* ...woof? 🤨`nTry: sit, speak, dance, fetch, roll over..." "*sar tilt* ...bhow? 🤨`nTry karo: baitho, bolo, naacho, fetch...") 35 }
    }
}

function Talk-ToKaalu {
    $t = [Microsoft.VisualBasic.Interaction]::InputBox("Give me a command, boss! (English ya Hindi)`n`nsit/baitho - speak/bolo - dance/naacho - jump/koodo - spin/ghoomo`nnap/so jao - come/aaja - stay/ruko - shabash - joke sunao - khana do`nroll over/palti - play dead/mar jao - shake/haath do - fetch`nopen <any app>  (e.g. 'open chrome' / 'chrome kholo')", "Talk to Kaalu 🗣", "")
    if (-not $t) { return }
    Obey-Command $t
}

# ------------------------------------------------------------
# Voice ears (offline Windows speech recognition)
# ------------------------------------------------------------
$script:VOICEWORDS = @(
    "sit", "sit down", "speak", "bark", "roll over", "play dead", "dance",
    "howl", "fetch", "good boy", "good dog", "jump", "spin", "come here",
    "come", "nap time", "go to sleep", "wake up", "chase", "stop", "stay",
    "tell me a joke", "joke", "high five", "shake", "shake hands", "hello",
    "stats", "treat",
    "baitho", "baith jao", "bolo", "bhonko", "naacho", "ghoomo", "palti",
    "mar jao", "koodo", "so jao", "utho", "idhar aao", "aaja", "ruko",
    "shabash", "khana do", "haath do", "haath milao", "namaste",
    "chuha pakdo", "joke sunao", "gend lao",
    "dig", "khodo", "khudai karo", "zoomies", "bhaago", "daudo", "run",
    "answer call", "answer the call", "call utha lo", "pick up",
    "zscaler status", "vpn status", "check vpn", "zscaler check",
    "zscaler check karo", "go home", "ghar jao", "ghar ja",
    "fly", "fly kaalu", "udo", "udaan bharo", "super kaalu",
    "spell check", "check spelling", "grammar check", "check this", "check text",
    "baith jaa", "aawa", "aav", "bhaunka", "bhaag", "shabaas", "pranaam",
    "ram ram", "ka ho", "kaa ho", "ghare jaa", "phaand", "jaag ja", "thahar",
    "noutube", "open noutube", "nou tube", "nou music", "play", "pause",
    "play pause", "next", "next video", "next song", "previous", "gaana bajao",
    "dance to music", "auto dance", "music mode",
    "transcribe", "dictation", "take notes", "start writing", "likho"
)

function Start-Voice([bool]$quiet = $false) {
    $phrases = New-Object System.Collections.Generic.List[string]
    [void]$phrases.Add("kaalu")
    foreach ($w in $script:VOICEWORDS) {
        [void]$phrases.Add($w)
        [void]$phrases.Add("kaalu $w")
    }
    foreach ($e in $script:INDEX) {
        if ($phrases.Count -gt 900) { break }
        $n = ("$($e.Name)" -replace "[^A-Za-z0-9 ]", " ") -replace "\s{2,}", " "
        $n = $n.Trim().ToLower()
        if ($n -and $n.Length -ge 3 -and $n.Length -le 32 -and (($n -replace "[^a-z]", "").Length -ge 3)) {
            [void]$phrases.Add("open " + $n)
            [void]$phrases.Add($n + " kholo")
        }
    }
    foreach ($ct in $script:slackContacts) {
        $n = "$($ct.name)".Trim().ToLower()
        if ($n) {
            [void]$phrases.Add("call " + $n)
            [void]$phrases.Add("huddle " + $n)
            [void]$phrases.Add("message " + $n)
            [void]$phrases.Add($n + " ko call karo")
        }
    }
    [KaaluVoice]::Start($phrases.ToArray())
    if ([KaaluVoice]::Status -eq "on") {
        $script:voiceOn = $true
        Save-Memory
        if (-not $quiet) { Say (TR "🎙 Ears ON! Say: sit, speak, dance,`nroll over, good boy, fetch..." "🎙 Kaan khul gaye! Bolo: baitho, bolo,`nnaacho, palti, shabash, fetch...") 50 }
    } else {
        $script:voiceOn = $false
        Save-Memory
        Say "😕 Couldn't reach your microphone.`nCheck Settings > Privacy > Microphone.`n($([KaaluVoice]::Status))" 60
    }
}

function Stop-Voice {
    try { [KaaluVoice]::Stop() } catch {}
    $script:voiceOn = $false
    Save-Memory
}

# ------------------------------------------------------------
# Desktop powers
# ------------------------------------------------------------
function Lock-Screen {
    Say (TR "Locking up! Guard mode 🔒" "Lock kar raha hoon! Guard mode 🔒") 15
    Start-Sleep -Milliseconds 600
    Start-Process "rundll32.exe" "user32.dll,LockWorkStation"
}

function Take-Screenshot {
    Say (TR "Say cheese! 📸" "Cheese boliye! 📸") 12; Flush-UI
    Start-Sleep -Milliseconds 400
    $oldLeft = $script:win.Left
    $script:win.Left = -20000
    $script:bub.Hide()
    Flush-UI
    Start-Sleep -Milliseconds 250
    try {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $g.Dispose()
        $desk = [Environment]::GetFolderPath('Desktop')
        $path = Join-Path $desk ("Kaalu_Screenshot_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".png")
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $script:win.Left = $oldLeft
        Say (TR "📸 Saved to your Desktop!`n$([IO.Path]::GetFileName($path))" "📸 Desktop par save ho gaya!`n$([IO.Path]::GetFileName($path))") 45
    } catch {
        $script:win.Left = $oldLeft
        Say (TR "Screenshot failed 😕" "Screenshot nahi bana 😕") 20
    }
}

function Empty-Bin {
    $a = [Microsoft.VisualBasic.Interaction]::MsgBox("Empty the Recycle Bin? This can't be undone.", 36, "Kaalu")
    if ("$a" -eq "Yes") {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            Say (TR "🗑 All clean! Buried the evidence 🐾" "🗑 Sab saaf! Saboot dafna diye 🐾") 30
        } catch {
            Say (TR "🗑 Already empty (or it wouldn't budge) 😅" "🗑 Pehle se khaali hai 😅") 25
        }
    }
}

function Show-Network {
    Say "Sniffing the network... 🐽" 40; Flush-UI
    $lines = @()
    try {
        $w = netsh wlan show interfaces 2>$null
        $ssid = ""; $sig = ""
        foreach ($ln in $w) {
            if ($ln -match '^\s+SSID\s+:\s*(.+)$')   { $ssid = $Matches[1].Trim() }
            if ($ln -match '^\s+Signal\s+:\s*(.+)$') { $sig = $Matches[1].Trim() }
        }
        if ($ssid) { $lines += "📶 Wi-Fi: $ssid ($sig)" } else { $lines += "📶 No Wi-Fi connection" }
    } catch {}
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254*' } |
            Select-Object -First 1).IPAddress
        if ($ip) { $lines += "🏠 Local IP: $ip" }
    } catch {}
    if (-not $lines) { $lines = @("Couldn't sniff anything 😕") }
    Say ($lines -join "`n") 60
}

# ------------------------------------------------------------
# Zscaler / VPN status
# ------------------------------------------------------------
function Show-Zscaler {
    Say (TR "Sniffing Zscaler... 🛡" "Zscaler soongh raha hoon... 🛡") 60; Flush-UI
    $lines = @()
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'ZSA*' })
    $tunnel = @($procs | Where-Object { $_.Name -eq 'ZSATunnel' })
    $svc = @($procs | Where-Object { $_.Name -eq 'ZSAService' })
    if ($svc.Count -gt 0 -and $tunnel.Count -gt 0) {
        $lines += (TR "🛡 Client Connector: running OK" "🛡 Client Connector: chal raha hai OK")
    } elseif ($procs.Count -gt 0) {
        $lines += "🛡 Client Connector: partial! ($($procs.Count) ZSA processes)"
    } else {
        $lines += (TR "🛡 Client Connector: NOT running!" "🛡 Client Connector: band hai!")
    }
    try {
        $r = Invoke-WebRequest -Uri "http://ip.zscaler.com/" -UseBasicParsing -TimeoutSec 6
        $t = $r.Content -replace '<[^>]+>', ' '
        if ($t -match 'via\s+Zscaler') {
            $cloud = ""
            if ($t -match 'Cloud:\s*([A-Za-z0-9 \-]+?)\s+in the\s+([a-z0-9\.]+)\s+cloud') {
                $cloud = "`n☁ Node: $($Matches[1].Trim()) ($($Matches[2]))"
            }
            $lines += (TR "🔒 Traffic secured via Zscaler OK$cloud" "🔒 Traffic Zscaler se ja raha hai OK$cloud")
        } else {
            $lines += (TR "⚠ Internet NOT going through Zscaler!" "⚠ Internet Zscaler se NAHI ja raha!")
        }
    } catch {
        $lines += (TR "🌐 Can't reach ip.zscaler.com (offline?)" "🌐 ip.zscaler.com nahi khula (offline?)")
    }
    Say ($lines -join "`n") 100
}

# ------------------------------------------------------------
# Spell & grammar helper (offline, opt-in only)
# Works ONLY on text you hand Kaalu - never monitors typing.
# ------------------------------------------------------------
$script:MISSPELL = @{
    'teh'='the';'recieve'='receive';'definately'='definitely';'seperate'='separate';
    'occured'='occurred';'occurance'='occurrence';'wich'='which';'thier'='their';
    'alot'='a lot';'untill'='until';'begining'='beginning';'beleive'='believe';
    'accross'='across';'agressive'='aggressive';'apparant'='apparent';'basicly'='basically';
    'calender'='calendar';'cemetary'='cemetery';'concious'='conscious';'embarass'='embarrass';
    'enviroment'='environment';'existance'='existence';'foriegn'='foreign';'goverment'='government';
    'gaurd'='guard';'harrass'='harass';'independant'='independent';'knowlege'='knowledge';
    'liason'='liaison';'maintainance'='maintenance';'neccessary'='necessary';'noticable'='noticeable';
    'occassion'='occasion';'persistant'='persistent';'posession'='possession';'prefered'='preferred';
    'priviledge'='privilege';'publically'='publicly';'realy'='really';'recomend'='recommend';
    'refered'='referred';'relevent'='relevant';'religous'='religious';'rythm'='rhythm';
    'succesful'='successful';'suprise'='surprise';'tommorow'='tomorrow';'truely'='truly';
    'unfortunatly'='unfortunately';'wierd'='weird';'writting'='writing';'accomodate'='accommodate';
    'adress'='address';'arguement'='argument';'commited'='committed';'completly'='completely';
    'dissapoint'='disappoint';'equiptment'='equipment';'familar'='familiar';
    'finaly'='finally';'grammer'='grammar';'happend'='happened';'immediatly'='immediately';
    'occuring'='occurring';'paralel'='parallel';'probaly'='probably';'quater'='quarter';
    'questionaire'='questionnaire';'sieze'='seize';'similiar'='similar';'speach'='speech';
    'threshhold'='threshold';'twelth'='twelfth';'vaccuum'='vacuum';
    'wanna'='want to';'gonna'='going to';'im'='I am';
    'plz'='please';'pls'='please';'thanx'='thanks';'ur'='your';
    'becuase'='because';'becasue'='because';'freind'='friend';'peice'='piece'
}

function Fix-Word([string]$w) {
    $lw = $w.ToLower()
    if ($script:MISSPELL.ContainsKey($lw)) {
        $c = $script:MISSPELL[$lw]
        if ($c -ceq $lw) { return $null }
        if ($w -cmatch '^[A-Z]') { $c = $c.Substring(0,1).ToUpper() + $c.Substring(1) }
        return $c
    }
    return $null
}

function Check-Text([string]$t) {
    $notes = New-Object System.Collections.Generic.List[string]
    if (-not "$t".Trim()) { return @{ fixed = ""; notes = $notes } }
    $fixed = $t

    # spelling (each distinct word once)
    $seen = @{}
    foreach ($mm in [regex]::Matches($t, "[A-Za-z']+")) {
        $w = $mm.Value; $lw = $w.ToLower()
        if ($seen.ContainsKey($lw)) { continue }
        $seen[$lw] = $true
        $c = Fix-Word $w
        if ($c) {
            $notes.Add("$w -> $c")
            $fixed = [regex]::Replace($fixed, "\b" + [regex]::Escape($w) + "\b", $c)
        }
    }

    # grammar heuristics (safe, deterministic)
    $b = $fixed; $fixed = $fixed -replace '  +', ' '
    if ($fixed -cne $b) { $notes.Add("removed extra spaces") }

    $b = $fixed; $fixed = [regex]::Replace($fixed, '\s+([,.!?;:])', '$1')
    if ($fixed -cne $b) { $notes.Add("fixed space before punctuation") }

    $b = $fixed; $fixed = [regex]::Replace($fixed, '\b(\w+)\s+\1\b', '$1', 'IgnoreCase')
    if ($fixed -cne $b) { $notes.Add("removed a repeated word") }

    $b = $fixed; $fixed = [regex]::Replace($fixed, '\bi\b', 'I')
    if ($fixed -cne $b) { $notes.Add("capitalized 'i'") }

    if ($fixed.Length -ge 1 -and ([string]$fixed[0]) -cmatch '[a-z]') {
        $fixed = $fixed.Substring(0,1).ToUpper() + $fixed.Substring(1)
        $notes.Add("capitalized first letter")
    }

    return @{ fixed = $fixed; notes = $notes }
}

# --- spell-check window ---
$script:spellFixed = ""
$script:spellWin = New-Object Windows.Window
$script:spellWin.Title = "Kaalu Spell Check"
$script:spellWin.Width = 430
$script:spellWin.Height = 400
$script:spellWin.WindowStyle = "None"
$script:spellWin.ResizeMode = "NoResize"
$script:spellWin.Topmost = $true
$script:spellWin.ShowInTaskbar = $false
$script:spellWin.ShowActivated = $true

$spRoot = New-Object Windows.Controls.Border
$spRoot.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(28,28,34))
$spRoot.BorderBrush = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(229,72,77))
$spRoot.BorderThickness = "2"
$spDock = New-Object Windows.Controls.DockPanel
$spDock.Margin = "10"
$spRoot.Child = $spDock
$script:spellWin.Content = $spRoot

$spTitle = New-Object Windows.Controls.TextBlock
$spTitle.Text = "📝 Paste or type text - Kaalu checks spelling & grammar"
$spTitle.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(235,235,240))
$spTitle.FontSize = 12
$spTitle.TextWrapping = "Wrap"
$spTitle.Margin = "0,0,0,6"
[Windows.Controls.DockPanel]::SetDock($spTitle, "Top")
$spDock.Children.Add($spTitle) | Out-Null

$script:spellIn = New-Object Windows.Controls.TextBox
$script:spellIn.AcceptsReturn = $true
$script:spellIn.TextWrapping = "Wrap"
$script:spellIn.Height = 90
$script:spellIn.FontSize = 13
$script:spellIn.VerticalScrollBarVisibility = "Auto"
[Windows.Controls.DockPanel]::SetDock($script:spellIn, "Top")
$spDock.Children.Add($script:spellIn) | Out-Null

$spBtns = New-Object Windows.Controls.StackPanel
$spBtns.Orientation = "Horizontal"
$spBtns.Margin = "0,6,0,6"
[Windows.Controls.DockPanel]::SetDock($spBtns, "Top")
$spDock.Children.Add($spBtns) | Out-Null

function New-SpBtn([string]$txt) {
    $b = New-Object Windows.Controls.Button
    $b.Content = $txt
    $b.Margin = "0,0,8,0"
    $b.Padding = "8,3,8,3"
    $b.FontSize = 12
    $spBtns.Children.Add($b) | Out-Null
    return $b
}

$script:spellOut = New-Object Windows.Controls.TextBox
$script:spellOut.IsReadOnly = $true
$script:spellOut.TextWrapping = "Wrap"
$script:spellOut.FontSize = 13
$script:spellOut.VerticalScrollBarVisibility = "Auto"
$script:spellOut.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(38,38,46))
$script:spellOut.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(230,230,235))
$spDock.Children.Add($script:spellOut) | Out-Null

function Run-SpellCheck {
    $res = Check-Text $script:spellIn.Text
    $script:spellFixed = $res.fixed
    $n = @($res.notes)
    if ($n.Count -eq 0) {
        $script:spellOut.Text = "Looks good to me! No fixes needed. 🐾"
        Say (TR "All good! No mistakes 🐾" "Sab sahi hai! Koi galti nahi 🐾") 20
    } else {
        $script:spellOut.Text = "Suggestions (" + $n.Count + "):`n- " + ($n -join "`n- ") + "`n`nFixed text:`n" + $res.fixed
        Say (TR "Found $($n.Count) fix(es)! 📝" "$($n.Count) galtiyan mili! 📝") 25
    }
}

$btnCheck = New-SpBtn "🔎 Check"
$btnCheck.Add_Click({ Run-SpellCheck })
$btnCopy = New-SpBtn "📋 Copy fixed"
$btnCopy.Add_Click({
    if ($script:spellFixed) {
        try { [Windows.Clipboard]::SetText($script:spellFixed); Say (TR "Copied fixed text! 📋" "Theek kiya text copy ho gaya! 📋") 20 } catch {}
    }
})
$btnClose = New-SpBtn "✖ Close"
$btnClose.Add_Click({ $script:spellWin.Hide() })

$script:spellWin.Add_Closing({ param($s, $e) $e.Cancel = $true; $script:spellWin.Hide() })
$script:spellIn.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq "Escape") { $script:spellWin.Hide(); $e.Handled = $true }
})

function Show-SpellCheck([string]$seed) {
    if (-not "$seed".Trim()) {
        try { $seed = [Windows.Clipboard]::GetText() } catch { $seed = "" }
    }
    $script:spellIn.Text = "$seed"
    $script:spellOut.Text = ""
    $script:spellFixed = ""
    $wx = $script:win.Left + $script:PW + 6
    if ($wx + 430 -gt $script:area.Right) { $wx = $script:win.Left - 436 }
    if ($wx -lt $script:area.Left) { $wx = $script:area.Left + 10 }
    $wy = $script:groundY + $script:PH - 400
    if ($wy -lt $script:area.Top) { $wy = $script:area.Top + 10 }
    $script:spellWin.Left = $wx
    $script:spellWin.Top = $wy
    $script:spellWin.Show()
    $script:spellWin.Activate() | Out-Null
    if ("$seed".Trim()) { Run-SpellCheck } else { Say (TR "Paste text & hit Check! 📝" "Text paste karo aur Check dabao! 📝") 25 }
    $script:spellIn.Focus() | Out-Null
}

# ------------------------------------------------------------
# Transcriber (offline dictation) - speak, Kaalu writes it down
# ------------------------------------------------------------
$script:transcribing = $false
$script:transcriptSB = New-Object System.Text.StringBuilder

$script:transWin = New-Object Windows.Window
$script:transWin.Title = "Kaalu Transcriber"
$script:transWin.Width = 460
$script:transWin.Height = 380
$script:transWin.WindowStyle = "None"
$script:transWin.ResizeMode = "NoResize"
$script:transWin.Topmost = $true
$script:transWin.ShowInTaskbar = $false
$script:transWin.ShowActivated = $true

$trRoot = New-Object Windows.Controls.Border
$trRoot.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(28,28,34))
$trRoot.BorderBrush = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(229,72,77))
$trRoot.BorderThickness = "2"
$trDock = New-Object Windows.Controls.DockPanel
$trDock.Margin = "10"
$trRoot.Child = $trDock
$script:transWin.Content = $trRoot

$script:trTitle = New-Object Windows.Controls.TextBlock
$script:trTitle.Text = "🎤 Speak - Kaalu is transcribing... (offline)"
$script:trTitle.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(235,235,240))
$script:trTitle.FontSize = 12
$script:trTitle.TextWrapping = "Wrap"
$script:trTitle.Margin = "0,0,0,6"
[Windows.Controls.DockPanel]::SetDock($script:trTitle, "Top")
$trDock.Children.Add($script:trTitle) | Out-Null

$trBtns = New-Object Windows.Controls.StackPanel
$trBtns.Orientation = "Horizontal"
$trBtns.Margin = "0,6,0,0"
[Windows.Controls.DockPanel]::SetDock($trBtns, "Bottom")
$trDock.Children.Add($trBtns) | Out-Null

function New-TrBtn([string]$txt) {
    $b = New-Object Windows.Controls.Button
    $b.Content = $txt; $b.Margin = "0,0,8,0"; $b.Padding = "8,3,8,3"; $b.FontSize = 12
    $trBtns.Children.Add($b) | Out-Null
    return $b
}

$script:transEditBox = New-Object Windows.Controls.TextBox
$script:transEditBox.IsReadOnly = $false
$script:transEditBox.TextWrapping = "Wrap"
$script:transEditBox.AcceptsReturn = $true
$script:transEditBox.FontSize = 13
$script:transEditBox.VerticalScrollBarVisibility = "Auto"
$script:transEditBox.Background = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(38,38,46))
$script:transEditBox.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(235,235,240))
$trDock.Children.Add($script:transEditBox) | Out-Null

function Stop-Transcribe {
    if (-not $script:transcribing) { return }
    $script:transcribing = $false
    try { [KaaluDictation]::Stop() } catch {}
    $script:trTitle.Text = "🎤 Stopped. Copy or Save your transcript."
    if ($script:voiceOn) { try { Start-Voice $true } catch {} }
    Say (TR "Done writing! 📝" "Likhna ho gaya! 📝" "Likh dihni ho! 📝") 25
}

function Save-Transcript {
    $t = $script:transEditBox.Text
    if (-not "$t".Trim()) { Say (TR "Nothing to save yet 😅" "Abhi kuch nahi likha 😅" "Abhi kuchho na likhail 😅") 20; return }
    try {
        $desk = [Environment]::GetFolderPath('Desktop')
        $path = Join-Path $desk ("Kaalu_Transcript_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".txt")
        [IO.File]::WriteAllText($path, $t, (New-Object Text.UTF8Encoding $true))
        Say (TR "📄 Saved to Desktop!`n$([IO.Path]::GetFileName($path))" "📄 Desktop par save!`n$([IO.Path]::GetFileName($path))") 45
    } catch { Say (TR "Save failed 😕" "Save nahi hua 😕") 20 }
}

$btnTrStop = New-TrBtn "⏹ Stop"
$btnTrStop.Add_Click({ Stop-Transcribe })
$btnTrCopy = New-TrBtn "📋 Copy"
$btnTrCopy.Add_Click({ try { [Windows.Clipboard]::SetText($script:transEditBox.Text); Say (TR "Copied! 📋" "Copy ho gaya! 📋") 15 } catch {} })
$btnTrSave = New-TrBtn "💾 Save to Desktop"
$btnTrSave.Add_Click({ Save-Transcript })
$btnTrClose = New-TrBtn "✖ Close"
$btnTrClose.Add_Click({ Stop-Transcribe; $script:transWin.Hide() })

$script:transWin.Add_Closing({ param($s, $e) $e.Cancel = $true; Stop-Transcribe; $script:transWin.Hide() })

function Start-Transcribe {
    if ($script:transcribing) { $script:transWin.Show(); $script:transWin.Activate() | Out-Null; return }
    try { [KaaluVoice]::Stop() } catch {}
    [KaaluDictation]::Start()
    if ([KaaluDictation]::Status -ne "on") {
        Say (TR "Can't reach the mic for dictation 😕" "Mic nahi mila dictation ke liye 😕" "Mic na milal 😕") 30
        if ($script:voiceOn) { try { Start-Voice $true } catch {} }
        return
    }
    [void]$script:transcriptSB.Clear()
    $script:transEditBox.Text = ""
    $script:transcribing = $true
    $script:trTitle.Text = "🎤 Speak - Kaalu is transcribing... (offline)"
    $wx = $script:win.Left + $script:PW + 6
    if ($wx + 460 -gt $script:area.Right) { $wx = $script:win.Left - 466 }
    if ($wx -lt $script:area.Left) { $wx = $script:area.Left + 10 }
    $wy = $script:groundY + $script:PH - 380
    if ($wy -lt $script:area.Top) { $wy = $script:area.Top + 10 }
    $script:transWin.Left = $wx; $script:transWin.Top = $wy
    $script:transWin.Show(); $script:transWin.Activate() | Out-Null
    Enter-State "sit" 250
    Say (TR "Go ahead - I'm writing it down! 📝🎤" "Bolo - main likh raha hoon! 📝🎤" "Bola - hum likhat baani! 📝🎤") 40
}

# ------------------------------------------------------------
# Context menu
# ------------------------------------------------------------
function New-MI($parent, [string]$header, [scriptblock]$action) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $header
    if ($action) { $mi.Add_Click($action) }
    $parent.Items.Add($mi) | Out-Null
    return $mi
}

function Add-Sep($parent) {
    $parent.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
}

$script:cm = New-Object Windows.Controls.ContextMenu
$script:cm.FontFamily = New-Object Windows.Media.FontFamily("Segoe UI, Segoe UI Emoji")

$script:miTitle = New-MI $script:cm "🐶 Kaalu, at your service!" $null
$script:miTitle.IsEnabled = $false
Add-Sep $script:cm

New-MI $script:cm "🦴 Give a treat (+10 XP)" { Give-Treat } | Out-Null
New-MI $script:cm "🎓 Teach next trick" { Teach-Trick } | Out-Null
New-MI $script:cm "🗣 Talk to Kaalu..." { Talk-ToKaalu } | Out-Null
New-MI $script:cm "📝 Spell & grammar check..." { Show-SpellCheck "" } | Out-Null
New-MI $script:cm "🎤 Transcribe (dictation)..." { Start-Transcribe } | Out-Null
$script:miVoice = New-MI $script:cm "🎙 Voice ears: OFF" {
    if ($script:voiceOn) {
        Stop-Voice
        Say (TR "Ears off! 🙉" "Kaan band! 🙉") 15
    } else {
        Start-Voice
    }
}
$script:miTts = New-MI $script:cm "📢 Kaalu's voice: ON" {
    $script:ttsOn = -not $script:ttsOn
    Save-Memory
    if ($script:ttsOn) {
        Say (TR "I can talk now! Woof! 📢" "Ab main bol sakta hoon! Bhow! 📢") 25
    } else {
        try { $script:tts.SpeakAsyncCancelAll() } catch {}
        Say (TR "Going quiet! 🤐 (bubbles only)" "Chup ho gaya! 🤐 (sirf bubbles)") 20
    }
}
$script:miLang = New-MI $script:cm "🌐 Language: हिन्दी (Hinglish)" {
    $script:lang = $(if ($script:lang -eq "hi") { "bho" } elseif ($script:lang -eq "bho") { "en" } else { "hi" })
    Save-Memory
    if ($script:lang -eq "hi") {
        Say "Ab main Hindi mein baat karunga! 🙏🐾`nBolo: baitho, naacho, bolo, shabash..." 45
    } elseif ($script:lang -eq "bho") {
        Say "Ab hum Bhojpuri mein baat karab ho! 🙏🐾`nBola: baith jaa, naacha, bhaunka, shabaas..." 45
    } else {
        Say "Switching back to English! 🐾" 30
    }
}
Add-Sep $script:cm

$miVol = New-MI $script:cm "🔊 Volume" $null
New-MI $miVol "🔊 Volume up (+10)" { Volume-Change "up" } | Out-Null
New-MI $miVol "🔉 Volume down (-10)" { Volume-Change "down" } | Out-Null
New-MI $miVol "🔇 Mute / Unmute" { Volume-Mute } | Out-Null

$miBri = New-MI $script:cm "🔆 Brightness" $null
New-MI $miBri "☀️ 100%" { Set-Brightness 100 } | Out-Null
New-MI $miBri "🔆 75%"  { Set-Brightness 75 } | Out-Null
New-MI $miBri "🌤 50%"  { Set-Brightness 50 } | Out-Null
New-MI $miBri "🌙 25%"  { Set-Brightness 25 } | Out-Null
Add-Sep $miBri
New-MI $miBri "➕ Brighter (+10)" { Nudge-Brightness 10 } | Out-Null
New-MI $miBri "➖ Dimmer (-10)"  { Nudge-Brightness -10 } | Out-Null

New-MI $script:cm "🔋 System stats" { Show-Stats } | Out-Null

$miApp = New-MI $script:cm "🚀 Launch" $null
New-MI $miApp "🔎 Apps, files & folders..." { Show-AppPicker "" } | Out-Null
Add-Sep $miApp
New-MI $miApp "📝 Notepad" { Launch-App "notepad" "Notepad" } | Out-Null
New-MI $miApp "🧮 Calculator" { Launch-App "calc" "Calculator" } | Out-Null
New-MI $miApp "🎨 Paint" { Launch-App "mspaint" "Paint" } | Out-Null
New-MI $miApp "📁 File Explorer" { Launch-App "explorer" "File Explorer" } | Out-Null
New-MI $miApp "💻 Terminal" { Launch-App "powershell" "PowerShell" } | Out-Null
New-MI $miApp "🌐 Website..." { Launch-Website } | Out-Null

$miSlk = New-MI $script:cm "💬 Slack" $null
New-MI $miSlk "💬 Open Slack" { try { Start-Process "slack://open" } catch {}; Say (TR "Opening Slack! 💬" "Slack khol raha hoon! 💬") 15 } | Out-Null
New-MI $miSlk "📞 Answer call (focus + join)" { Answer-SlackCall } | Out-Null
Add-Sep $miSlk
foreach ($ct in $script:slackContacts) {
    $miC = New-Object Windows.Controls.MenuItem
    $miC.Header = "📞 Call $($ct.full)"
    $miC.Tag = $ct.name
    $miC.Add_Click({ Call-SlackContact $this.Tag })
    $miSlk.Items.Add($miC) | Out-Null
    $miM = New-Object Windows.Controls.MenuItem
    $miM.Header = "💬 Message $($ct.full)"
    $miM.Tag = $ct.name
    $miM.Add_Click({ Open-SlackDM $this.Tag | Out-Null })
    $miSlk.Items.Add($miM) | Out-Null
}

$miNou = New-MI $script:cm "🎵 NouTube" $null
New-MI $miNou "🎵 Open / focus NouTube" { Open-NouTube } | Out-Null
New-MI $miNou "⏯ Play / Pause" { Media-Key "playpause" } | Out-Null
New-MI $miNou "⏭ Next" { Media-Key "next" } | Out-Null
New-MI $miNou "⏮ Previous" { Media-Key "prev" } | Out-Null
$script:miMusic = New-MI $miNou "🎶 Dance to music: ON" {
    $script:musicOn = -not $script:musicOn
    Save-Memory
    if ($script:musicOn) {
        Say (TR "I'll dance to the music! 🎶" "Gaane pe naachunga! 🎶" "Gaane pe naachab ho! 🎶") 25
    } else {
        if ($script:state -eq "musicdance") { Enter-State "idle" 20 }
        Say (TR "Music dance off 🔇" "Music dance band 🔇" "Music dance band ho 🔇") 20
    }
}

$miTim = New-MI $script:cm "⏰ Timers & reminders" $null
New-MI $miTim "☕ 5 minutes"  { Start-KTimer 5 "" } | Out-Null
New-MI $miTim "🍅 25 minutes (pomodoro)" { Start-KTimer 25 "" } | Out-Null
New-MI $miTim "⏲ Custom timer..." { Ask-Timer } | Out-Null
New-MI $miTim "📌 Reminder..." { Ask-Reminder } | Out-Null

$miFun = New-MI $script:cm "🎾 Tricks & play" $null
New-MI $miFun "🐕 Speak!" { Do-Bark } | Out-Null
New-MI $miFun "😂 Tell a joke" { Say (Pick-Joke) 60 } | Out-Null
New-MI $miFun "🌀 Spin!" { Enter-State "spin" 16 } | Out-Null
New-MI $miFun "🐭 Chase my cursor!" { Say (TR "I'll get it! 🐾" "Abhi pakadta hoon! 🐾") 15; Enter-State "chase" 150 } | Out-Null
New-MI $miFun "🦘 Jump!" { Enter-State "jump" 10 } | Out-Null
New-MI $miFun "🦇 Super Kaalu (fly!)" { Start-Flight } | Out-Null
New-MI $miFun "😴 Nap time (go home)" { Say (TR "Heading to my house! 🏠" "Ghar ja raha hoon! 🏠") 20; Enter-State "gohome" 999 } | Out-Null
Add-Sep $miFun

$script:trickMIs = @{}
foreach ($tr in $script:TRICKS) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $tr.name
    $mi.Tag = $tr.id
    $mi.Add_Click({ Do-Trick $this.Tag })
    $miFun.Items.Add($mi) | Out-Null
    $script:trickMIs[$tr.id] = $mi
}

$miPow = New-MI $script:cm "🛠 More powers" $null
New-MI $miPow "🔒 Lock screen" { Lock-Screen } | Out-Null
New-MI $miPow "📸 Screenshot to Desktop" { Take-Screenshot } | Out-Null
New-MI $miPow "🗑 Empty Recycle Bin" { Empty-Bin } | Out-Null
New-MI $miPow "📶 Wi-Fi / IP info" { Show-Network } | Out-Null
New-MI $miPow "🛡 Zscaler / VPN status" { Show-Zscaler } | Out-Null

Add-Sep $script:cm
$script:miRoam = New-MI $script:cm "📌 Stay here (stop roaming)" {
    $script:roam = -not $script:roam
    if ($script:roam) {
        $script:miRoam.Header = "📌 Stay here (stop roaming)"
        Say (TR "Roaming again! 🚶" "Phir se ghoomna shuru! 🚶") 15
        Enter-State "idle" 10
    } else {
        $script:miRoam.Header = "🚶 Start roaming"
        Say (TR "Staying right here! 📌" "Yahin baithunga! 📌") 15
        Enter-State "idle" 9999
    }
}

$miSize = New-MI $script:cm "📏 Size" $null
New-MI $miSize "Small"  { Set-PetScale 4 } | Out-Null
New-MI $miSize "Medium" { Set-PetScale 5 } | Out-Null
New-MI $miSize "Large"  { Set-PetScale 7 } | Out-Null

Add-Sep $script:cm
New-MI $script:cm "❌ Bye Kaalu" {
    Say (TR "Bye! See you soon 🐾" "Bye bye! Phir milenge 🐾") 20
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(1.2)
    $t.Add_Tick({ $this.Stop(); try { $script:bub.Close() } catch {}; $script:win.Close() })
    $t.Start()
} | Out-Null

$script:img.ContextMenu = $script:cm

function Set-PetScale([int]$s) {
    $script:SCALE = $s
    $script:PW = $script:GW * $s
    $script:PH = $script:GH * $s
    $script:win.Width = $script:PW
    $script:win.Height = $script:PH
    $script:groundY = $script:area.Bottom - $script:PH
    $script:win.Top = $script:groundY
    Say (TR "How do I look? 🐶" "Kaisa lag raha hoon? 🐶") 20
}

$script:cm.Add_Opened({
    $script:paused = $true
    $script:miTitle.Header = "🐶 Kaalu   ⭐ Level $(Get-Level)   🦴 $($script:xp) XP"
    $script:miVoice.Header = $(if ($script:voiceOn) { "🎙 Voice ears: ON" } else { "🎙 Voice ears: OFF" })
    $script:miTts.Header = $(if ($script:ttsOn) { "📢 Kaalu's voice: ON" } else { "📢 Kaalu's voice: OFF" })
    $script:miLang.Header = $(if ($script:lang -eq "hi") { "🌐 Language: हिन्दी (Hinglish)" } elseif ($script:lang -eq "bho") { "🌐 Language: भोजपुरी (Bhojpuri)" } else { "🌐 Language: English" })
    $script:miMusic.Header = $(if ($script:musicOn) { "🎶 Dance to music: ON" } else { "🎶 Dance to music: OFF" })
    foreach ($tr in $script:TRICKS) {
        $mi = $script:trickMIs[$tr.id]
        if ($script:learned -contains $tr.id) {
            $mi.Header = $tr.name
            $mi.IsEnabled = $true
        } else {
            $mi.Header = "🔒 $($tr.name)  (needs $($tr.xp) XP)"
            $mi.IsEnabled = $false
        }
    }
})
$script:cm.Add_Closed({ $script:paused = $false })

# ------------------------------------------------------------
# Mouse input: drag / click=menu / double-click=bark
# ------------------------------------------------------------
$script:clickTimer = New-Object Windows.Threading.DispatcherTimer
$script:clickTimer.Interval = [TimeSpan]::FromMilliseconds(260)
$script:clickTimer.Add_Tick({
    $this.Stop()
    $script:cm.PlacementTarget = $script:img
    $script:cm.IsOpen = $true
})

$script:img.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($script:state -eq "sleep") {
        Enter-State "idle" 20
        Play-Bark; Say (TR "I'm up! I'm up! 🐶" "Uth gaya, uth gaya! 🐶") 20
        return
    }
    if ($e.ClickCount -ge 2 -or $script:clickTimer.IsEnabled) {
        $script:clickTimer.Stop()
        Do-Bark
        return
    }
    $before = New-Object Windows.Point($script:win.Left, $script:win.Top)
    try { $script:win.DragMove() } catch {}
    $moved = [Math]::Abs($script:win.Left - $before.X) + [Math]::Abs($script:win.Top - $before.Y)
    if ($moved -lt 5) {
        $script:clickTimer.Start()
    } else {
        if ($script:win.Top -lt $script:groundY - 10) {
            Enter-State "drop" 999
        } else {
            $script:win.Top = $script:groundY
            Enter-State "idle" 30
        }
    }
})

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------
$script:loop = New-Object Windows.Threading.DispatcherTimer
$script:loop.Interval = [TimeSpan]::FromMilliseconds(100)
$script:loop.Add_Tick({ try { Do-Tick } catch {} })

$script:win.Add_Loaded({
    $script:loop.Start()
    try { $script:audioOk = [KaaluAudio]::Init() } catch { $script:audioOk = $false }
    # place the doghouse in the bottom-right corner
    try {
        $script:houseWin.Left = $script:area.Right - $script:houseWin.Width - 24
        $script:houseWin.Top = $script:area.Bottom - $script:houseWin.Height
        $script:houseWin.Show()
    } catch {}
    Play-Bark
    $ears = ""
    if ($script:voiceOn) {
        Start-Voice $true
        if ($script:voiceOn) { $ears = TR "`n🎙 I'm listening! Say 'sit', 'dance', 'good boy'..." "`n🎙 Sun raha hoon! Bolo: 'baitho', 'naacho', 'shabash'..." "`n🎙 Sunat baani ho! Bola: 'baith jaa', 'naacha', 'shabaas'..." }
    }
    if (@($script:learned).Count -eq 0) {
        Say (TR "Woof! I'm Kaalu 🐾 Feed me treats 🦴 and teach me tricks!$ears" "Bhow! Main Kaalu hoon 🐾 Treats khilao 🦴 aur tricks sikhao!$ears" "Bhow! Hum Kaalu baani ho 🐾 Treat khiyava 🦴 aur trick sikhava!$ears") 90
    } else {
        Say (TR "Woof! Kaalu reporting — Level $(Get-Level), $(@($script:learned).Count) tricks learned! 🎓$ears" "Bhow! Kaalu hazir — Level $(Get-Level), $(@($script:learned).Count) tricks seekh chuka! 🎓$ears" "Bhow! Kaalu hajir ba ho — Level $(Get-Level), $(@($script:learned).Count) trick seekh leni! 🎓$ears") 80
    }
    # load the Start Menu app index shortly after boot, then refresh
    # the voice grammar so "open <app>" works by voice too
    $bootT = New-Object Windows.Threading.DispatcherTimer
    $bootT.Interval = [TimeSpan]::FromSeconds(3)
    $bootT.Add_Tick({
        $this.Stop()
        Load-Apps
        Load-Files
        Rebuild-Index
        if ($script:voiceOn) { Start-Voice $true }
    })
    $bootT.Start()
})

$script:win.Add_Closed({
    try { $script:loop.Stop() } catch {}
    try { if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() } } catch {}
    try { [KaaluVoice]::Stop() } catch {}
    try { if ($script:tts) { $script:tts.SpeakAsyncCancelAll(); $script:tts.Dispose() } } catch {}
    try { $script:bub.Close() } catch {}
    try { $script:ballWin.Close() } catch {}
    try { $script:houseWin.Close() } catch {}
    try { $script:mtx.ReleaseMutex() } catch {}
})

# ------------------------------------------------------------
# System tray icon + controls
# ------------------------------------------------------------
$script:hidden = $false

function Hide-Kaalu {
    $script:hidden = $true
    try { $script:win.Hide() } catch {}
    try { $script:bub.Hide() } catch {}
    try { $script:houseWin.Hide() } catch {}
    try { $script:ballWin.Hide() } catch {}
    try { if ($script:pick) { $script:pick.Hide() } } catch {}
    try { if ($script:spellWin) { $script:spellWin.Hide() } } catch {}
}

function Show-Kaalu {
    $wasHidden = $script:hidden
    $script:hidden = $false
    try { $script:win.Show(); $script:win.Topmost = $true } catch {}
    try { $script:houseWin.Show() } catch {}
    if ($wasHidden) { Play-Bark; Say (TR "I'm back! 🐾" "Wapas aa gaya! 🐾" "Wapas aa gaili ho! 🐾") 25 }
}

function Close-Kaalu {
    try { if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() } } catch {}
    try { $script:win.Close() } catch {}
}

function Terminate-Kaalu {
    # write the terminate flag (blocks all relaunch until reboot)
    try { Set-Content -Path (Join-Path $script:dir "kaalu_terminated.flag") -Value (Get-Date -Format o) -Encoding UTF8 } catch {}
    # stop the watchdog scheduled task
    try { & schtasks.exe /Change /TN 'KaaluDesktopBuddy' /DISABLE 2>$null | Out-Null } catch {}
    # kill any other Kaalu instances
    try {
        $me = $PID
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*Kaalu*kaalu.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch {}
    try { if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() } } catch {}
    try { $script:win.Close() } catch {}
}

# tray icon image (little black puppy face)
try {
    $tbmp = New-Object System.Drawing.Bitmap 32, 32
    $tg = [System.Drawing.Graphics]::FromImage($tbmp)
    $tg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $tg.Clear([System.Drawing.Color]::Transparent)
    $bBlack = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38, 38, 46))
    $bAmber = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(198, 124, 43))
    $bNose  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(10, 10, 12))
    $tg.FillEllipse($bBlack, 2, 1, 10, 13)
    $tg.FillEllipse($bBlack, 20, 1, 10, 13)
    $tg.FillEllipse($bBlack, 3, 7, 26, 23)
    $tg.FillEllipse($bAmber, 10, 14, 4, 4)
    $tg.FillEllipse($bAmber, 18, 14, 4, 4)
    $tg.FillEllipse($bNose, 13, 20, 6, 5)
    $tg.Dispose()
    $script:trayIco = [System.Drawing.Icon]::FromHandle($tbmp.GetHicon())
} catch { $script:trayIco = [System.Drawing.SystemIcons]::Application }

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Text = "Kaalu - your desktop buddy 🐾"
$script:tray.Icon = $script:trayIco
$script:tray.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$hdr = $trayMenu.Items.Add("🐶  Kaalu"); $hdr.Enabled = $false
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itOpen = $trayMenu.Items.Add("Open  (show + menu)")
$itShow = $trayMenu.Items.Add("Unhide / Show")
$itHide = $trayMenu.Items.Add("Hide")
$itClose = $trayMenu.Items.Add("Close  (exits; auto-restarts)")
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itTerm = $trayMenu.Items.Add("Terminate  (stay off until reboot)")

$itOpen.Add_Click({ Show-Kaalu; try { $script:cm.PlacementTarget = $script:img; $script:cm.IsOpen = $true } catch {} })
$itShow.Add_Click({ Show-Kaalu })
$itHide.Add_Click({ Hide-Kaalu })
$itClose.Add_Click({ Close-Kaalu })
$itTerm.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show("Terminate Kaalu completely?`n`nHe will stop now and will NOT restart until you reboot your PC.", "Kaalu - Terminate", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { Terminate-Kaalu }
})
$script:tray.ContextMenuStrip = $trayMenu
$script:tray.Add_MouseDoubleClick({ if ($script:hidden) { Show-Kaalu } else { Hide-Kaalu } })

$script:win.ShowDialog() | Out-Null
