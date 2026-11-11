# Privacy Policy — PeekPane & PeekPane Tab Extractor

**Last updated:** November 2026

**PeekPane** (macOS desktop application) and **PeekPane Tab Extractor** (Chromium & Firefox/Gecko browser companion extensions) do **not** collect, store, transmit, sell, or share any personal data, browsing history, page content, analytics, or telemetry.

## How Data Is Handled

1. **100% Local Processing (`127.0.0.1` Loopback Only)**:
   - When you explicitly click the PeekPane toolbar button or press the configured keyboard shortcut (`⌥⇧P`) on a browser tab, the extension captures visual frames of that tab (`chrome.tabCapture` on Chromium or `browser.tabs.captureTab` on Firefox/Gecko) and streams them exclusively over an authenticated loopback WebSocket (`ws://127.0.0.1:<port>`) to the **PeekPane** app running on your own Mac.
   - Zero frames, URLs, tab titles, or metadata ever leave your device or traverse any external network.
2. **Local Browser Storage (`storage.local`)**:
   - Stores only a randomly generated local session UUID and your local macOS browser bundle identifier for pairing with the PeekPane desktop app.
3. **Native Messaging (`com.peekpane.bridge`)**:
   - Used solely to read the local loopback WebSocket port/token and launch the installed **PeekPane** macOS application when requested by you.
4. **No Third-Party Services**:
   - Neither the macOS app nor the browser extensions embed any third-party SDKs, trackers, crash reporters, or remote scripts.

## Contact

For questions or security disclosures, please open an issue at [https://github.com/rituraj22/PeekPane/issues](https://github.com/rituraj22/PeekPane/issues).
