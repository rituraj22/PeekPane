<p align="center">
  <img src="AppIcon.svg" width="120" height="120" alt="PeekPane App Icon" />
</p>

<h1 align="center">PeekPane</h1>

<p align="center">
  <strong>Turn any slice of any Mac window into a live, always-on-top, click-through floating pane.</strong><br/>
  Crop a flight progress bar, stock ticker, live sports score, delivery map, or terminal log—and keep just that compact region floating at 60 FPS while you work.
</p>

<p align="center">
  <a href="https://github.com/rituraj22/PeekPane/releases/latest"><img src="https://img.shields.io/badge/Download-v1.3_Release-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="Download Latest Release" /></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B_(Sonoma_%2F_Sequoia)-1E293B?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14.0+" />
  <img src="https://img.shields.io/badge/Arch-Universal_(Apple_Silicon_%26_Intel)-334155?style=for-the-badge" alt="Universal Binary" />
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-10B981?style=for-the-badge" alt="MIT License" /></a>
</p>

<p align="center">
  <em>✨ Built 100% using <strong>Gemini Argon + Antigravity</strong></em>
</p>

<p align="center">
  <img src="assets/clip1-select-and-crop.gif" width="760" alt="PeekPane — Select a window, crop just the compact flight progress bar, and float it over your IDE" />
</p>

---

## 💡 Why PeekPane?

Most macOS apps force an all-or-nothing choice: either dedicate half your screen to an entire browser or app window, or bury it behind your active workspace and constantly `⌘ Tab` back to check it.

**PeekPane** lets you **slice out only the compact region you actually care about**—like a `PAT ✈ HYD` flight progress bar on Flightradar24, a single TradingView candle chart, a live match score, or a CI build log—and float it anywhere on your screen at **60 FPS**. Even when the source window is completely covered by your IDE or other apps, your floating pane stays live.

---

## 🎬 Live Walkthrough: Tracking a Flight While Coding in Antigravity

Suppose you are tracking a live flight (**IndiGo `IGO6127`** on [Flightradar24](https://www.flightradar24.com/IGO6127/42835550)) in **Google Chrome** while writing Swift code in **Antigravity**. Instead of keeping the full browser window open, here is how **PeekPane** keeps just the live progress bar in view without ever blocking your editor:

### 1. ✂️ Cut Out the Clutter — Select, Crop & Float
Pick any open window from the **PeekPane** sidebar and drag the 8-handle crop box tightly around the exact strip you want—here, just the **`PAT ✈ HYD` schedule & yellow flight progress bar**. Click **Create Floating Pane** and switch back to your code editor.

<p align="center">
  <img src="assets/clip1-select-and-crop.gif" width="760" alt="Step 1: Select Flightradar24 in Chrome, crop just the PAT-HYD yellow progress bar, and float it over Antigravity" />
</p>

---

### 2. 👻 Ghost Mode & Custom Transparency — Work Right Underneath the Overlay
Normally, a floating window covers up whatever code or UI buttons sit behind it. **Ghost Mode** solves this by turning your floating pane into a **see-through, click-through overlay**:

1. **Dial in Custom Transparency (`20%` – `100%`)**: Drag the top HUD slider so you can clearly see both your live flight bar and the Swift code behind it.
2. **Click, Select Text & Scroll Right Through It**: Click the **Ghost icon** (`👻`) on the HUD. Your mouse now passes straight through the floating pane—you can **select code, type, trigger inline actions, and scroll** in the editor directly behind the overlay.
3. **Hold `⌥ Option` Anytime to Grab & Move (`✋`)**: Need to reposition a Ghost Mode pane? Hold **`⌥ Option`** while hovering over it—your pointer switches to a **Grab Hand (`✋`)** so you can smoothly drag, resize, or toggle Ghost Mode off without triggering macOS window-tiling snap.

<p align="center">
  <img src="assets/clip2-ghost-mode-antigravity.gif" width="760" alt="Step 2: Lower transparency, enable Ghost Mode, select and scroll code directly behind the translucent overlay, and hold Option to drag it" />
</p>

---

### 3. 🎛️ Live In-Place Crop Adjustment — Reveal More Without Starting Over
Want to peek at the live radar map right next to the `PAT ✈ HYD` status card without returning to the main window?
* Hover over the floating pane and click the **Crop (`crop`)** button in the top HUD (the border highlights in blue).
* **Drag any edge or corner** of the floating pane outward to **reveal more of the underlying window in place** (or drag inside to pan and scroll to zoom) without stretching the image.
* Click **Crop** again to lock the new region.

<p align="center">
  <img src="assets/clip3-live-crop-adjust.gif" width="760" alt="Step 3: Toggle Crop Mode on the floating pane and drag the right edge outward to reveal the live radar map in place" />
</p>

---

### 4. ↗️ One-Click `↗ Go` to Source Window
When the flight lands—or whenever you want to interact with the full source window—hover over the floating pane and click the **`↗ Go`** pill in the bottom-right corner. **PeekPane** immediately raises and focuses that exact source window, even if the app has multiple windows open across displays.

<p align="center">
  <img src="assets/clip4-go-to-source.gif" width="760" alt="Step 4: Click the bottom-right Go button on the floating pane to bring the full Google Chrome Flightradar24 window to the front" />
</p>

---

### 5. 🌐 Direct Browser Tab Extraction (Chrome, Arc, Brave, Edge & Vivaldi)
Floating a browser window works anytime—and with the bundled **PeekPane Tab Extractor** extension, you can float an **individual browser tab directly** without toolbars:
* **Switch Tabs Freely**: Keep a background tab streaming live at ~24 FPS even when you switch to another tab in the same browser window, minimize the browser, or move across Spaces.
* **Toolbar Click or `⌥⇧P` Direct Crop**: Click the PeekPane extension icon (or press **`⌥⇧P`**), hover to auto-snap to any card/chart/video or drag a custom box (or click **Float Full Tab**), and PeekPane floats it immediately—launching silently in the background without a Dock icon or main window if PeekPane wasn't open yet.
* **One-Click Setup & Handoff from PeekPane**: Use the **Browser Tabs** section in the PeekPane sidebar (or the prompt shown when selecting any Chromium window) to install the bundled unpacked extension from `~/Library/Application Support/PeekPane/Extension` or jump straight to your browser to pick a tab.

---

## 🎯 Everyday Use Cases

| Use Case | What You Can Float |
| :--- | :--- |
| **✈️ Flight, Ride & Delivery Trackers** | Float just the live progress bar, ETA strip, or courier map from Flightradar24, Uber, DoorDash, or Swiggy/Zomato until arrival. |
| **📈 Stocks, Crypto & Financial Tickers** | Crop a single TradingView candle chart, Apple Stocks watchlist row, order book, or portfolio balance and pin it to the corner while you work. |
| **⚽ Live Sports Scores & Timers** | Float just the live scoreboard, cricket/football ticker, or F1 timing tower from a browser window without keeping a cluttered webpage open. |
| **🛠️ Terminal Logs, CI/CD & Metrics** | Watch a running build, `docker compose` log, GitHub Actions workflow, or Grafana graph with **Ghost Mode** enabled so clicks pass right through it. |
| **🎥 Videos, Streams & Calls Without PiP** | Give any video player, Twitch/YouTube live chat, Zoom/Meet participant tile, or security camera feed a custom-cropped Picture-in-Picture window. |
| **🎨 Design References & Live Previews** | Float a cropped Figma component, UI spec, or localhost preview right beside (or translucently over) your IDE. |
| **🧩 Mini-Widgets from Native Mac Apps** | Turn a slice of Notes, Calendar, Weather, Activity Monitor, or Reminders into a compact, always-visible desktop widget. |

---

## 🕹️ Floating Pane Controls at a Glance

Hover over any floating pane to reveal its HUD controls:

| Control | Location | What It Does |
| :--- | :--- | :--- |
| **Switch Window** (`arrow.triangle.2.circlepath`) | Top HUD | Opens a live menu of all open windows to switch the pane's source on the fly. |
| **Adjust Crop** (`crop`) | Top HUD | Toggles **Crop Mode** (blue border). Drag inside to pan, scroll to zoom, or drag window edges to expand/shrink the cropped region in place. |
| **Transparency Slider** | Top HUD | Smoothly adjusts the floating pane's opacity from `20%` to `100%`. |
| **Ghost Mode** (`👻`) | Top HUD | Makes the pane 100% click-through so mouse clicks, text selection, and scrolling pass to windows underneath. Hold `⌥ Option` to grab or interact. |
| **Close** (`xmark`) | Top HUD | Stops the stream and closes the floating pane. |
| **Go to Window** (`↗ Go`) | Bottom-Right | Raises and focuses the exact captured source window, even among multiple windows of the same app. |
| **Grab & Move** (`✋`) | Anywhere on Pane | Drag inside the pane (away from resize edges) in normal mode—or hold `⌥ Option` in Ghost Mode—to move the floating window smoothly. |

> [!TIP]
> You can also disable **Ghost Mode** across all active panes at once from the **PeekPane icon (`pip`) in your macOS Menu Bar**.

---

## 🚀 Installation

### Requirements
* **macOS 14.0 (Sonoma)** or later (Universal Binary for Apple Silicon & Intel)
* **Screen Recording Permission** *(prompted when streaming Mac app windows via `ScreenCaptureKit`; not required for Browser Tab Extraction)*
* **Accessibility Permission** *(optional, prompted only when using `↗ Go` to raise a specific window among multiple windows of the same app)*

### Option 1: Install via Homebrew (Recommended)
```bash
brew tap rituraj22/peekpane https://github.com/rituraj22/PeekPane.git
brew install --cask peekpane
```

### Option 2: Download Prebuilt `.dmg` or `.zip`
Download [**`PeekPane-1.3-macos.dmg`**](https://github.com/rituraj22/PeekPane/releases/latest) or [**`PeekPane-1.3-macos.zip`**](https://github.com/rituraj22/PeekPane/releases/latest) from the [Releases](https://github.com/rituraj22/PeekPane/releases) page, drag **PeekPane.app** to `/Applications`, and launch it.

### Option 3: Build from Source
```bash
# Build native PeekPane.app and launch
make app
open PeekPane.app

# Or build and install directly into /Applications
make install

# Build Universal Binary (arm64 + x86_64) & package release .zip, .dmg, and SHA256SUMS
make release
```

---

## ⚡ Architecture & Performance

**PeekPane** is built in pure Swift (`strict` concurrency) using **AppKit**, **CoreAnimation**, **ScreenCaptureKit**, **VideoToolbox**, and **Network.framework**:
* **Zero-Copy 60 FPS GPU Window Pipeline**: Frames arrive from `SCStream` as `CMSampleBuffer` backed by GPU `IOSurface` objects and are assigned directly to `videoLayer.contents` inside a pure AppKit `NSPanel` (`VideoSurfaceNSView`)—zero `NSImage`/`CGImage` per-frame allocations and zero CPU pixel copies.
* **Zero-Copy Browser Tab Pipeline**: The bundled MV3 Chromium extension captures a tab's compositor output in an offscreen document via `chrome.tabCapture` + hardware `WebCodecs` H.264 (`avcC`), streams compact binary packets over an authenticated loopback WebSocket (`127.0.0.1`), and decodes directly via `VTDecompressionSession` into `IOSurface`-backed `CVPixelBuffer` surfaces shared across panes.
* **Normalized Crop & In-Place Edge Expansion**: Cropping is represented in normalized top-left window/viewport coordinates (`NormalizedCropRect`), allowing instant switching between proportional window scaling and in-place crop expansion.

```text
PeekPane/
├── Package.swift                 # SwiftPM manifest (.macOS(.v14), strict concurrency)
├── Info.plist                    # App bundle metadata (com.peekpane.app, v1.3)
├── Entitlements.plist            # macOS Screen Capture & Apple Events entitlements
├── AppIcon.svg                   # Liquid Glass vector app icon source
├── Makefile                      # Standardized build, lint, test, universal & release targets
├── build_app.sh                  # Universal/native .app builder, icon generator & inside-out signer
├── scripts/package_release.sh    # Packages .zip, .dmg, SHA256SUMS & updates Homebrew Cask
├── Casks/peekpane.rb             # Homebrew Cask specification
├── ARCHITECTURE.md               # Deep-dive technical architecture & rendering design
├── Extension/                    # Bundled MV3 Chromium extension (tabCapture + WebCodecs H.264)
├── assets/                       # Real screen-recorded walkthrough GIFs
├── Sources/
│   ├── PeekPaneBridgeWire/       # Shared binary wire header, avcC parser & Native Messaging framing
│   ├── PeekPaneNativeHost/       # Native Messaging CLI bridge (probe & silent --background bootstrap)
│   └── PeekPane/
│       ├── PeekPaneApp.swift     # @main App entry point, managed Main Window & --background mode
│       ├── Models/
│       │   └── CaptureSessionModel.swift        # NormalizedCropRect, CaptureSource & browser models
│       ├── Services/
│       │   ├── CaptureStreamEngine.swift        # Unified zero-copy stream protocol & CVPixelBuffer payload
│       │   ├── WindowDiscoveryService.swift     # SCShareableContent + CGWindowList Z-order discovery
│       │   ├── WindowFocusHelper.swift          # AXUIElement + CGWindowList target window focus helper
│       │   ├── WindowStreamEngine.swift         # 60 FPS SCStream zero-copy IOSurface capture engine
│       │   ├── ExtensionBundleManager.swift     # Atomic extension staging & NativeMessagingHosts setup
│       │   ├── BrowserBridgeServer.swift        # Authenticated 127.0.0.1 WebSocket control/stream server
│       │   ├── BrowserBridgeServer+Routing.swift# Control/binary packet routing & heartbeat monitor
│       │   ├── BrowserBridgeMessages.swift      # Typed control envelopes & session handoff models
│       │   ├── H264StreamDecoder.swift          # Hardware VTDecompressionSession -> IOSurface decoder
│       │   └── TabStreamEngine.swift            # Shared per-tab stream fan-out & active-rect unletterbox
│       └── Views/
│           ├── MainControlView.swift            # AppCoordinator & main window split-view UI
│           ├── AppCoordinator+BrowserTabs.swift # Flow 1/Flow 2 browser tab session & handoff actions
│           ├── BrowserTabsSection.swift         # Sidebar Browser Tabs launcher & connection status
│           ├── ChromiumWindowBanner.swift       # Contextual Chromium window QoL suggestion banner
│           ├── ExtensionSetupSheetView.swift    # Guided unpacked extension setup & staging helper
│           ├── BrowserHandoffBannerPanel.swift  # Non-activating Flow 2 browser guidance HUD panel
│           ├── InteractiveCropCanvas.swift      # Interactive crop canvas with dynamic cursors
│           ├── FloatingPlayerPanel.swift        # FloatingPlayerSession & pure AppKit NSPanel
│           ├── FloatingPlayerSession+Source.swift # Source switching & window/browser activation
│           ├── VideoSurfaceNSView.swift         # CALayer GPU surface, active-rect projection & cursors
│           └── FloatingPlayerHUDViews.swift     # Pure AppKit HUD controls, slider & banners
└── Tests/
    └── PeekPaneBridgeWireTests/  # Unit tests for wire packets, avcC parsing & Native Messaging
```

For a deep dive into the rendering pipeline and coordinate math, see **[ARCHITECTURE.md](./ARCHITECTURE.md)**.

---

## 📄 License

Released under the [MIT License](./LICENSE).

---

<p align="center">
  Built 100% using <strong>Gemini Argon + Antigravity</strong>
</p>
