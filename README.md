<p align="center">
  <img src="AppIcon.svg" width="120" height="120" alt="PeekPane App Icon" />
</p>

<h1 align="center">PeekPane</h1>

<p align="center">
  <strong>Turn any slice of any Mac window—or any individual browser tab—into a live, always-on-top, click-through floating pane.</strong><br/>
  Crop a flight progress bar, stock ticker, live sports score, delivery map, or terminal log—and keep just that compact region floating while you work.
</p>

<p align="center">
  <a href="https://github.com/rituraj22/PeekPane/releases/latest"><img src="https://img.shields.io/badge/Download-v2.0_Release-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="Download Latest Release" /></a>
  <a href="https://addons.mozilla.org/en-US/firefox/addon/peekpane-tab-extractor/"><img src="https://img.shields.io/badge/Firefox_&_Zen_Add--on-Install-FF7139?style=for-the-badge&logo=firefoxbrowser&logoColor=white" alt="Firefox & Zen Add-on" /></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B_(Sonoma_%2F_Sequoia_%2F_Tahoe)-1E293B?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 14.0+" />
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

## 🆕 What's New in PeekPane 2.0

* **🌐 Direct Browser Tab Extraction (12 Chromium & Gecko Browsers)**: Float any region or full viewport of an individual background browser tab **without toolbars** and **without macOS Screen Recording permission**—keep switching tabs, minimizing the browser, or moving across Spaces while your pane keeps streaming:
  * **Chromium Browsers (~24 FPS GPU H.264)**: **Google Chrome**, **Arc**, **Brave**, **Microsoft Edge**, **Vivaldi**, and **Chromium**.
  * **Firefox & Gecko Forks (~12–15 FPS Compositor Snapshots)**: **Firefox**, **Firefox Developer Edition**, **Zen Browser**, **LibreWolf**, **Floorp**, and **Waterfox** *(ideal for dashboards, tickers, trackers, and logs)*.
* **🎯 In-Tab Smart Element Snap & Silent Cold-Launch (`⌥⇧P`)**: Click the PeekPane extension button or press **`⌥⇧P`** on any webpage to hover-snap to cards/charts/videos or drag a custom crop box. If PeekPane isn't running yet, the native host boots it silently in `--background` accessory mode with zero Dock icon or main window interruption.
* **↗️ Tab-Aware `↗ Go` & Live Metadata Sync**: Clicking **`↗ Go`** on a browser-tab pane activates that exact background tab inside your browser and brings its window forward.
* **🔨 Side-by-Side `PeekPaneDev` Local Build Variant**: Source builds (`make app`, `make install`) now produce a distinct `PeekPaneDev.app` (`com.peekpane.app.dev`) with a squircle-clipped `DEV` ribbon and toolbar/menu-bar indicators so local development never overwrites or collides with an installed production `PeekPane.app`.

---

## 💡 Why PeekPane?

Most macOS apps force an all-or-nothing choice: either dedicate half your screen to an entire browser or app window, or bury it behind your active workspace and constantly `⌘ Tab` back to check it.

**PeekPane** lets you **slice out only the compact region you actually care about**—like a `PAT ✈ HYD` flight progress bar on Flightradar24, a single TradingView candle chart, a live match score, or a CI build log—and float it anywhere on your screen. Even when the source window is completely covered by your IDE—or when you switch away from a captured browser tab—your floating pane stays live.

---

## 🎬 Live Walkthrough: Tracking a Flight While Coding in Antigravity

Suppose you are tracking a live flight (**IndiGo `IGO6127`** on [Flightradar24](https://www.flightradar24.com/IGO6127/42835550)) in **Google Chrome** while writing Swift code in **Antigravity**. Instead of keeping the full browser window open, here is how **PeekPane** keeps just the live progress bar in view without ever blocking your editor:

### 1. ✂️ Cut Out the Clutter — Select, Crop & Float
Pick any open window from the **PeekPane** sidebar, choose a quick preset from the **2×3 visual region grid** or drag the 8-handle crop box tightly around the exact strip you want—here, just the **`PAT ✈ HYD` schedule & yellow flight progress bar**. Click **Create Floating Pane** and switch back to your code editor.

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
* **Drag any edge or corner** of the floating pane outward to **reveal more of the underlying window or tab in place** (or drag inside to pan and scroll to zoom) without stretching the image.
* Click **Crop** again to lock the new region.

<p align="center">
  <img src="assets/clip3-live-crop-adjust.gif" width="760" alt="Step 3: Toggle Crop Mode on the floating pane and drag the right edge outward to reveal the live radar map in place" />
</p>

---

### 4. ↗️ One-Click `↗ Go` to Source Window or Browser Tab
When the flight lands—or whenever you want to interact with the full source—hover over the floating pane and click the **`↗ Go`** pill in the bottom-right corner. **PeekPane** immediately raises and focuses that exact source window (even among multiple windows of the same app) or activates the exact background browser tab.

<p align="center">
  <img src="assets/clip4-go-to-source.gif" width="760" alt="Step 4: Click the bottom-right Go button on the floating pane to bring the full Google Chrome Flightradar24 window to the front" />
</p>

---

### 5. 🌐 Direct Browser Tab Extraction (Chromium + Firefox & Gecko Forks)
Floating a browser window via `ScreenCaptureKit` works out of the box—and with the bundled **PeekPane Tab Extractor** extensions, you can float an **individual browser tab directly** without browser chrome across **Chrome, Arc, Brave, Edge, Vivaldi, Chromium**, and **Firefox, Firefox Developer Edition, Zen Browser, LibreWolf, Floorp, Waterfox**:

* **Switch Tabs & Minimize Freely**: Keep a background tab streaming live (~24 FPS GPU `WebCodecs` H.264 on Chromium; ~12–15 FPS `tabs.captureTab` compositor snapshots on Firefox/Zen) even while you browse other tabs, minimize the browser window, or switch Spaces.
* **Toolbar Click or `⌥⇧P` Direct Crop**: Click the PeekPane toolbar icon (or press **`⌥⇧P`**) on any tab, hover to auto-snap to any card/chart/video, drag a custom box, or press `Enter` / click **Float Full Tab**. PeekPane opens the floating pane immediately—starting silently in the background if it wasn't running yet.
* **Guided One-Click Setup & Live Detection**: PeekPane automatically detects installed browsers and whether the extension is active on disk or connected live:
  * **Firefox, Zen Browser, LibreWolf, Floorp & Waterfox**: Install permanently in one click from [**Mozilla Add-ons (`PeekPane Tab Extractor`)**](https://addons.mozilla.org/en-US/firefox/addon/peekpane-tab-extractor/) (or click **Open in Firefox / Zen →** directly inside PeekPane's **Browser Tabs** setup sheet).
  * **Chrome, Arc, Brave, Edge, Vivaldi & Chromium**: Use PeekPane's guided **Browser Tabs** setup sheet to load the staged extension from `~/Library/Application Support/PeekPane/Extension`.
  > **Note on Gecko frame rate:** Because Gecko lacks Chromium's `tabCapture` video API, Firefox/Zen tab extraction streams ~12–15 FPS snapshots—ideal for dashboards, tickers, trackers, and logs; for 60 FPS video in Firefox/Zen, use full-window capture or the browser's built-in Picture-in-Picture.

---

## 🎯 Everyday Use Cases

| Use Case | What You Can Float |
| :--- | :--- |
| **✈️ Flight, Ride & Delivery Trackers** | Float just the live progress bar, ETA strip, or courier map from Flightradar24, Uber, DoorDash, or Swiggy/Zomato until arrival. |
| **📈 Stocks, Crypto & Financial Tickers** | Crop a single TradingView candle chart, Apple Stocks watchlist row, order book, or portfolio balance and pin it to the corner while you work. |
| **⚽ Live Sports Scores & Timers** | Float just the live scoreboard, cricket/football ticker, or F1 timing tower from a background browser tab without keeping a cluttered page open. |
| **🛠️ Terminal Logs, CI/CD & Metrics** | Watch a running build, `docker compose` log, GitHub Actions workflow, or Grafana graph with **Ghost Mode** enabled so clicks pass right through it. |
| **🎥 Videos, Streams & Calls Without PiP** | Give any video player, Twitch/YouTube live chat, Zoom/Meet participant tile, or security camera feed a custom-cropped Picture-in-Picture window. |
| **🎨 Design References & Live Previews** | Float a cropped Figma component, UI spec, or `localhost` preview right beside (or translucently over) your IDE. |
| **🧩 Mini-Widgets from Native Mac Apps** | Turn a slice of Notes, Calendar, Weather, Activity Monitor, or Reminders into a compact, always-visible desktop widget. |

---

## 🕹️ Floating Pane Controls at a Glance

Hover over any floating pane to reveal its HUD controls:

| Control | Location | What It Does |
| :--- | :--- | :--- |
| **Switch Source** (`arrow.triangle.2.circlepath`) | Top HUD | Opens a live menu of configured browser tab pickers and open Mac windows to switch the pane's source on the fly. |
| **Adjust Crop** (`crop`) | Top HUD | Toggles **Crop Mode** (blue border). Drag inside to pan, scroll to zoom, or drag window edges to expand/shrink the cropped region in place. |
| **Transparency Slider** | Top HUD | Smoothly adjusts the floating pane's opacity from `20%` to `100%`. |
| **Ghost Mode** (`👻`) | Top HUD | Makes the pane 100% click-through so mouse clicks, text selection, and scrolling pass to windows underneath. Hold `⌥ Option` to grab or interact. |
| **Close** (`xmark`) | Top HUD | Stops the stream and closes the floating pane. |
| **Go to Source** (`↗ Go`) | Bottom-Right | Raises and focuses the exact captured source window—or activates and focuses the exact background browser tab. |
| **Grab & Move** (`✋`) | Anywhere on Pane | Drag inside the pane (away from resize edges) in normal mode—or hold `⌥ Option` in Ghost Mode—to move the floating window smoothly. |

> [!TIP]
> You can also disable **Ghost Mode** across all active panes at once from the **PeekPane icon in your macOS Menu Bar**.

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
Download [**`PeekPane-2.0-macos.dmg`**](https://github.com/rituraj22/PeekPane/releases/latest) or [**`PeekPane-2.0-macos.zip`**](https://github.com/rituraj22/PeekPane/releases/latest) from the [Releases](https://github.com/rituraj22/PeekPane/releases) page, drag **PeekPane.app** to `/Applications`, and launch it.

### Option 3: Build from Source
Local builds default to **`PeekPaneDev.app`** (`com.peekpane.app.dev`, with a `DEV` corner ribbon on the app icon, toolbar badge, and menu bar indicator) so they coexist cleanly alongside an installed production **`PeekPane.app`**:
```bash
# Build native local dev bundle (PeekPaneDev.app) and launch
make app
open PeekPaneDev.app

# Or build and install PeekPaneDev.app into /Applications (without overwriting PeekPane.app)
make install

# Build clean production bundle (PeekPane.app) locally
make prod-app

# Build Universal Production Release (PeekPane.app) & package .zip, .dmg, and SHA256SUMS
make release
```

---

## ⚡ Architecture & Performance

**PeekPane** is built in pure Swift (`strict` concurrency) using **AppKit**, **CoreAnimation**, **ScreenCaptureKit**, **VideoToolbox**, and **Network.framework**:
* **Zero-Copy 60 FPS GPU Window Pipeline**: Frames arrive from `SCStream` as `CMSampleBuffer` backed by GPU `IOSurface` objects and are assigned directly to `videoLayer.contents` inside a pure AppKit `NSPanel` (`VideoSurfaceNSView`)—zero `NSImage`/`CGImage` per-frame allocations and zero CPU pixel copies.
* **Dual-Engine Browser Tab Pipeline (Chromium + Gecko)**: Chromium browsers capture a tab's compositor output via `chrome.tabCapture` + hardware `WebCodecs` H.264 (`avcC`) decoded directly into `IOSurface` buffers via `VTDecompressionSession` (`H264StreamDecoder`). Firefox and Gecko forks (`Zen`, `LibreWolf`, `Floorp`, `Waterfox`) capture background tabs via `browser.tabs.captureTab` JPEG frames (~12–15 FPS with unchanged-frame deduplication) decoded into pooled `IOSurface`-backed `CVPixelBuffer` surfaces (`JPEGFrameDecoder`).
* **Normalized Crop & In-Place Edge Expansion**: Cropping is represented in normalized top-left window/viewport coordinates (`NormalizedCropRect`), allowing instant switching between proportional window scaling and in-place crop expansion.

```text
PeekPane/
├── Package.swift                 # SwiftPM manifest (.macOS(.v14), strict concurrency)
├── VERSION                       # Single source of truth for release version (2.0)
├── Info.plist                    # App bundle metadata template (com.peekpane.app, v2.0)
├── Entitlements.plist            # macOS Screen Capture & Apple Events entitlements
├── AppIcon.svg                   # Liquid Glass vector macOS app icon source
├── ExtensionIcon.svg             # Minimal transparent-background browser extension icon source
├── Makefile                      # Standardized build, lint, analyze, test, dev & release targets
├── lint.sh                       # Strict swift-format + SwiftLint + SwiftLint static analyzer
├── build_app.sh                  # Dev/prod universal .app builder, icon generator & inside-out signer
├── scripts/
│   ├── package_release.sh            # Packages .zip, .dmg, SHA256SUMS & updates Homebrew Cask
│   └── package_firefox_extension.sh  # Validates & packages Firefox AMO archive / signed .xpi
├── Casks/peekpane.rb             # Homebrew Cask specification
├── ARCHITECTURE.md               # Deep-dive technical architecture & rendering design
├── PRIVACY.md                    # Local-only zero-telemetry privacy policy
├── Extension/                    # Bundled MV3 Chromium extension (tabCapture + WebCodecs H.264)
├── FirefoxExtension/             # Bundled MV2 Firefox/Gecko extension (tabs.captureTab JPEG)
├── assets/                       # Real screen-recorded walkthrough GIFs
├── Sources/
│   ├── PeekPaneBridgeWire/       # Shared 28-byte wire header, avcC parser & Native Messaging framing
│   ├── PeekPaneNativeHost/       # Native Messaging CLI bridge (probe & silent --background bootstrap)
│   └── PeekPane/
│       ├── PeekPaneApp.swift     # @main App entry point, managed Main Window & --background mode
│       ├── Models/
│       │   └── CaptureSessionModel.swift          # NormalizedCropRect, AppBuildIdentity & browser models
│       ├── Services/
│       │   ├── CaptureStreamEngine.swift          # Unified zero-copy stream protocol & CVPixelBuffer payload
│       │   ├── WindowDiscoveryService.swift       # SCShareableContent + CGWindowList Z-order discovery
│       │   ├── WindowFocusHelper.swift            # AXUIElement + CGWindowList target window focus helper
│       │   ├── WindowStreamEngine.swift           # 60 FPS SCStream zero-copy IOSurface capture engine
│       │   ├── ExtensionBundleManager.swift       # Extension staging, NativeMessagingHosts & profile detector
│       │   ├── BrowserBridgeServer.swift          # Authenticated 127.0.0.1 WebSocket control/stream server
│       │   ├── BrowserBridgeServer+Routing.swift  # Control/binary packet routing & heartbeat monitor
│       │   ├── BrowserBridgeMessages.swift        # Typed control envelopes & session handoff models
│       │   ├── H264StreamDecoder.swift            # Hardware VTDecompressionSession + JPEG dispatch decoder
│       │   ├── JPEGFrameDecoder.swift             # Pooled IOSurface JPEG decoder for Firefox/Gecko streams
│       │   └── TabStreamEngine.swift              # Coalesced per-pane tab stream consumer
│       └── Views/
│           ├── MainControlView.swift              # AppCoordinator, 2×3 preset grid & main split-view UI
│           ├── AppCoordinator+BrowserTabs.swift   # Flow 1/Flow 2 browser tab session & handoff actions
│           ├── BrowserTabsSection.swift           # Sidebar Browser Tabs launcher & live connection status
│           ├── ChromiumWindowBanner.swift         # Contextual Chromium/Gecko window suggestion banner
│           ├── ExtensionSetupSheetView.swift      # Guided Chromium & Gecko extension setup sheet
│           ├── BrowserHandoffBannerPanel.swift    # Non-activating Flow 2 browser guidance HUD panel
│           ├── InteractiveCropCanvas.swift        # Interactive 8-handle crop canvas with dynamic cursors
│           ├── FloatingPlayerPanel.swift          # FloatingPlayerSession & pure AppKit NSPanel
│           ├── FloatingPlayerSession+Source.swift # Source switching & window/browser tab activation
│           ├── VideoSurfaceNSView.swift           # CALayer GPU surface, active-rect projection & cursors
│           └── FloatingPlayerHUDViews.swift       # Pure AppKit HUD controls, slider & banners
└── Tests/
    └── PeekPaneBridgeWireTests/  # Unit tests for H.264/JPEG wire packets, origins, avcC & framing
```

For a deep dive into the rendering pipeline, browser bridge security model, and coordinate math, see **[ARCHITECTURE.md](./ARCHITECTURE.md)**.

---

## 📄 License

Released under the [MIT License](./LICENSE).

---

<p align="center">
  Built 100% using <strong>Gemini Argon + Antigravity</strong>
</p>
