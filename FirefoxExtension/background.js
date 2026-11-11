(() => {
  'use strict';

  const api = typeof browser !== 'undefined' ? browser : chrome;
  const actionApi = api.browserAction || api.action;

  const NATIVE_HOST_NAME = 'com.peekpane.bridge';
  const PROTOCOL_VERSION = 1;
  const HEADER_BYTES = 28;
  const MAGIC_BYTE_0 = 0x50;
  const MAGIC_BYTE_1 = 0x50;
  const FLAG_KEYFRAME_JPEG = 0x01 | 0x04;

  const PROBE_ALARM_NAME = 'peekpane-firefox-bridge-probe';
  const STORAGE_INSTANCE_ID_KEY = 'peekpaneFirefoxInstanceId';
  const STORAGE_LAST_BUNDLE_ID_KEY = 'peekpaneFirefoxLastBundleId';
  const STORAGE_LAST_AUTO_RELOAD_KEY = 'peekpaneFirefoxLastAutoReloadTargetVersion';

  const OVERLAY_SETTLE_MS = 80;
  const ACTIVE_CAPTURE_INTERVAL_MS = 72; // ~14 FPS
  const IDLE_CAPTURE_INTERVAL_MS = 180;  // ~5.5 FPS when unchanged
  const UNCHANGED_BACKOFF_FRAMES = 5;
  const MAX_LONG_EDGE_PX = 1920;
  const JPEG_QUALITY = 78;
  const MAX_WS_BUFFERED_BYTES = 1024000;
  const FAST_RECONNECT_DELAYS_MS = [1500, 3000, 6000];

  /** @type {WebSocket | null} */
  let controlWs = null;
  let controlWsAuthenticated = false;

  /** @type {WebSocket | null} */
  let streamWs = null;
  let streamWsAuthenticated = false;

  let currentEndpoint = null;
  let cachedInstanceId = null;
  let cachedBrowserBundleId = '';
  let badgeResetTimer = null;
  let disconnectCleanupTimer = null;
  let reconnectTimer = null;
  let fastReconnectAttempt = 0;
  let connectInFlightPromise = null;
  let pendingAutoReloadVersion = null;
  let globalMonotonicTimestampUs = 0;

  /**
   * tabId -> TabCaptureSession
   * @type {Map<number, {
   *   tabId: number,
   *   viewportWidth: number,
   *   viewportHeight: number,
   *   dpr: number,
   *   title: string,
   *   urlHost: string,
   *   seq: number,
   *   lastDataUrl: string,
   *   lastJpegBytes: Uint8Array | null,
   *   unchangedCount: number,
   *   inFlight: boolean,
   *   forceSendNext: boolean,
   *   stopped: boolean,
   *   timerId: number | null,
   *   tickCount: number
   * }>}
   */
  const captureSessions = new Map();

  function getManifestVersion() {
    return (api.runtime.getManifest && api.runtime.getManifest().version) || '1.1';
  }

  function parseSemverTuple(versionStr) {
    return String(versionStr || '0.0.0')
      .split('.')
      .slice(0, 3)
      .map((part) => {
        const num = Number.parseInt(part, 10);
        return Number.isFinite(num) ? num : 0;
      });
  }

  function isSemverGreater(candidate, baseline) {
    const a = parseSemverTuple(candidate);
    const b = parseSemverTuple(baseline);
    for (let i = 0; i < 3; i += 1) {
      if ((a[i] || 0) > (b[i] || 0)) return true;
      if ((a[i] || 0) < (b[i] || 0)) return false;
    }
    return false;
  }

  async function maybeScheduleExtensionReload(stagedVersion) {
    if (!stagedVersion || !isSemverGreater(stagedVersion, getManifestVersion())) {
      return;
    }
    const stored = await api.storage.local.get([STORAGE_LAST_AUTO_RELOAD_KEY]);
    if (stored[STORAGE_LAST_AUTO_RELOAD_KEY] === stagedVersion) {
      return;
    }
    pendingAutoReloadVersion = stagedVersion;
    runDeferredReloadIfIdle();
  }

  function runDeferredReloadIfIdle() {
    if (!pendingAutoReloadVersion || captureSessions.size > 0) return;
    const targetVersion = pendingAutoReloadVersion;
    pendingAutoReloadVersion = null;
    api.storage.local.set({ [STORAGE_LAST_AUTO_RELOAD_KEY]: targetVersion }).then(() => {
      api.runtime.reload();
    }).catch(() => {});
  }

  function nextMonotonicTimestampUs() {
    const candidate = Math.floor(performance.now() * 1000);
    if (candidate <= globalMonotonicTimestampUs) {
      globalMonotonicTimestampUs += 1000;
    } else {
      globalMonotonicTimestampUs = candidate;
    }
    return globalMonotonicTimestampUs;
  }

  async function getOrCreateExtensionInstanceId() {
    if (cachedInstanceId) return cachedInstanceId;
    const stored = await api.storage.local.get([STORAGE_INSTANCE_ID_KEY, STORAGE_LAST_BUNDLE_ID_KEY]);
    if (stored[STORAGE_LAST_BUNDLE_ID_KEY] && !cachedBrowserBundleId) {
      cachedBrowserBundleId = stored[STORAGE_LAST_BUNDLE_ID_KEY];
    }
    if (stored[STORAGE_INSTANCE_ID_KEY]) {
      cachedInstanceId = stored[STORAGE_INSTANCE_ID_KEY];
      return cachedInstanceId;
    }
    const generated = crypto.randomUUID();
    await api.storage.local.set({ [STORAGE_INSTANCE_ID_KEY]: generated });
    cachedInstanceId = generated;
    return generated;
  }

  function detectFallbackBrowserBundleId() {
    if (cachedBrowserBundleId) return cachedBrowserBundleId;
    const ua = navigator.userAgent || '';
    if (ua.includes('Zen/')) return 'app.zen-browser.zen';
    if (ua.includes('LibreWolf')) return 'io.gitlab.librewolf-community.librewolf';
    if (ua.includes('Floorp/')) return 'one.ablaze.floorp';
    if (ua.includes('Waterfox/')) return 'net.waterfox.waterfox';
    return 'org.mozilla.firefox';
  }

  async function discoverActionShortcut() {
    try {
      const commands = await api.commands.getAll();
      const executeCmd = commands.find(
        (cmd) => cmd.name === '_execute_browser_action' || cmd.name === '_execute_action'
      );
      return (executeCmd && executeCmd.shortcut) ? executeCmd.shortcut : '';
    } catch (_) {
      return '';
    }
  }

  function flashBadge(text, backgroundHex, durationMs) {
    if (!actionApi) return;
    clearTimeout(badgeResetTimer);
    Promise.resolve(actionApi.setBadgeBackgroundColor({ color: backgroundHex })).catch(() => {});
    Promise.resolve(actionApi.setBadgeText({ text })).catch(() => {});
    if (durationMs > 0) {
      badgeResetTimer = setTimeout(() => {
        Promise.resolve(actionApi.setBadgeText({ text: '' })).catch(() => {});
      }, durationMs);
    }
  }

  function decodeBase64ToBytes(base64Str) {
    if (typeof Uint8Array.fromBase64 === 'function') {
      return Uint8Array.fromBase64(base64Str);
    }
    const binary = atob(base64Str);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) {
      out[i] = binary.charCodeAt(i);
    }
    return out;
  }

  function packJpegWirePacket(tabId, seq, timestampUs, viewportWidth, viewportHeight, jpegBytes) {
    const packet = new Uint8Array(HEADER_BYTES + jpegBytes.byteLength);
    const view = new DataView(packet.buffer);
    view.setUint8(0, MAGIC_BYTE_0);
    view.setUint8(1, MAGIC_BYTE_1);
    view.setUint8(2, PROTOCOL_VERSION);
    view.setUint8(3, FLAG_KEYFRAME_JPEG);
    view.setUint32(4, tabId >>> 0, false);
    view.setUint32(8, seq >>> 0, false);

    const high = Math.floor(timestampUs / 0x100000000) >>> 0;
    const low = timestampUs >>> 0;
    view.setUint32(12, high, false);
    view.setUint32(16, low, false);

    const vw = Math.max(64, Math.min(65535, Math.round(viewportWidth || 1280)));
    const vh = Math.max(64, Math.min(65535, Math.round(viewportHeight || 800)));
    view.setUint16(20, vw, false);
    view.setUint16(22, vh, false);
    view.setUint16(24, 0, false);
    view.setUint16(26, 0, false);

    packet.set(jpegBytes, HEADER_BYTES);
    return packet;
  }

  async function callNativeHost(type) {
    try {
      const response = await api.runtime.sendNativeMessage(NATIVE_HOST_NAME, { type });
      if (response && response.callerBundleIdentifier) {
        cachedBrowserBundleId = response.callerBundleIdentifier;
        api.storage.local.set({ [STORAGE_LAST_BUNDLE_ID_KEY]: cachedBrowserBundleId }).catch(() => {});
      }
      return response || null;
    } catch (err) {
      console.warn('[PeekPane] Native host call failed:', type, err);
      return null;
    }
  }

  function isControlConnected() {
    return controlWs !== null && controlWs.readyState === WebSocket.OPEN && controlWsAuthenticated;
  }

  function isStreamConnected() {
    return streamWs !== null && streamWs.readyState === WebSocket.OPEN && streamWsAuthenticated;
  }

  function sendControlJson(payload) {
    if (!isControlConnected()) return false;
    try {
      controlWs.send(JSON.stringify(payload));
      return true;
    } catch (_) {
      return false;
    }
  }

  function scheduleFastReconnect() {
    if (reconnectTimer !== null) return;
    if (isControlConnected() && isStreamConnected()) {
      fastReconnectAttempt = 0;
      return;
    }
    if (fastReconnectAttempt >= FAST_RECONNECT_DELAYS_MS.length) {
      return;
    }
    const delayMs = FAST_RECONNECT_DELAYS_MS[fastReconnectAttempt];
    fastReconnectAttempt += 1;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      ensureBridgeReady({ allowBootstrap: false }).then((ok) => {
        if (!ok) {
          scheduleFastReconnect();
        }
      }).catch(() => {});
    }, delayMs);
  }

  function openAuthenticatedSocket(role, endpoint) {
    return new Promise((resolve) => {
      let settled = false;
      const finish = (ok, ws) => {
        if (settled) return;
        settled = true;
        resolve(ok ? ws : null);
      };

      let ws;
      try {
        ws = new WebSocket(`ws://127.0.0.1:${endpoint.wsPort}`);
        ws.binaryType = 'arraybuffer';
      } catch (err) {
        console.warn('[PeekPane] Failed to construct WebSocket:', err);
        finish(false, null);
        return;
      }

      const timeout = setTimeout(() => {
        try {
          ws.close();
        } catch (_) {}
        finish(false, null);
      }, 4500);

      ws.onopen = async () => {
        const instanceId = await getOrCreateExtensionInstanceId();
        const bundleId = detectFallbackBrowserBundleId();
        const shortcut = role === 'control' ? await discoverActionShortcut() : '';
        const hello = {
          type: 'hello',
          protocolVersion: PROTOCOL_VERSION,
          role,
          extensionInstanceId: instanceId,
          browserBundleId: bundleId,
          extensionVersion: getManifestVersion(),
          actionShortcut: shortcut,
          token: endpoint.token
        };
        try {
          ws.send(JSON.stringify(hello));
        } catch (_) {
          clearTimeout(timeout);
          finish(false, null);
        }
      };

      ws.onmessage = (event) => {
        if (typeof event.data !== 'string') return;
        let msg = null;
        try {
          msg = JSON.parse(event.data);
        } catch (_) {
          return;
        }
        if (!msg) return;

        if (msg.type === 'hello_ack') {
          clearTimeout(timeout);
          if (role === 'control') {
            controlWs = ws;
            controlWsAuthenticated = true;
            if (msg.stagedExtensionVersion) {
              maybeScheduleExtensionReload(msg.stagedExtensionVersion).catch(() => {});
            }
          } else {
            streamWs = ws;
            streamWsAuthenticated = true;
          }
          fastReconnectAttempt = 0;
          clearTimeout(reconnectTimer);
          reconnectTimer = null;
          clearTimeout(disconnectCleanupTimer);
          disconnectCleanupTimer = null;
          finish(true, ws);
          return;
        }

        if (role === 'control') {
          handleControlServerMessage(msg);
        }
      };

      ws.onerror = (err) => {
        console.warn(`[PeekPane] WebSocket (${role}) error on port ${endpoint.wsPort}:`, err);
        clearTimeout(timeout);
        finish(false, null);
      };

      ws.onclose = () => {
        clearTimeout(timeout);
        let wasActiveSocket = false;
        if (role === 'control' && controlWs === ws) {
          controlWs = null;
          controlWsAuthenticated = false;
          wasActiveSocket = true;
        } else if (role === 'stream' && streamWs === ws) {
          streamWs = null;
          streamWsAuthenticated = false;
          wasActiveSocket = true;
        }
        scheduleOrphanCaptureCleanup();
        if (wasActiveSocket) {
          fastReconnectAttempt = 0;
          scheduleFastReconnect();
        }
        finish(false, null);
      };
    });
  }

  function scheduleOrphanCaptureCleanup() {
    if (captureSessions.size === 0) return;
    if (isControlConnected() && isStreamConnected()) return;
    clearTimeout(disconnectCleanupTimer);
    disconnectCleanupTimer = setTimeout(() => {
      if (!isControlConnected() || !isStreamConnected()) {
        stopAllCaptureSessions();
      }
    }, 3500);
  }

  async function connectBridgeInternal(allowBootstrap) {
    if (isControlConnected() && isStreamConnected()) {
      return true;
    }

    let hostResp = await callNativeHost('probe');
    if ((!hostResp || !hostResp.running) && allowBootstrap) {
      hostResp = await callNativeHost('bootstrap');
    }
    if (hostResp && hostResp.stagedExtensionVersion) {
      maybeScheduleExtensionReload(hostResp.stagedExtensionVersion).catch(() => {});
    }
    if (!hostResp || !hostResp.ok || !hostResp.running || !hostResp.wsPort || !hostResp.token) {
      return false;
    }

    currentEndpoint = {
      wsPort: hostResp.wsPort,
      token: hostResp.token
    };

    const promises = [];
    if (!isControlConnected()) {
      promises.push(openAuthenticatedSocket('control', currentEndpoint));
    }
    if (!isStreamConnected()) {
      promises.push(openAuthenticatedSocket('stream', currentEndpoint));
    }
    await Promise.all(promises);
    return isControlConnected() && isStreamConnected();
  }

  async function ensureBridgeReady({ allowBootstrap }) {
    if (isControlConnected() && isStreamConnected()) {
      return true;
    }
    if (connectInFlightPromise) {
      const existingResult = await connectInFlightPromise;
      if (existingResult || !allowBootstrap) {
        return existingResult;
      }
    }
    connectInFlightPromise = connectBridgeInternal(allowBootstrap).finally(() => {
      connectInFlightPromise = null;
    });
    return connectInFlightPromise;
  }

  function handleControlServerMessage(msg) {
    switch (msg.type) {
      case 'ping':
        sendControlJson({ type: 'pong' });
        break;

      case 'highlight_action_badge':
        flashBadge('PICK', '#0A84FF', 6000);
        break;

      case 'request_keyframe':
        if (typeof msg.tabId === 'number') {
          const session = captureSessions.get(msg.tabId);
          if (session && !session.stopped) {
            session.forceSendNext = true;
            if (session.lastJpegBytes && isStreamConnected()) {
              emitJpegPacket(session, session.lastJpegBytes);
            }
            triggerImmediateCaptureTick(session);
          }
        }
        break;

      case 'stop_tab_capture':
        if (typeof msg.tabId === 'number') {
          stopCaptureSession(msg.tabId);
        }
        break;

      case 'activate_tab':
        if (typeof msg.tabId === 'number') {
          activateBrowserTab(msg.tabId);
        }
        break;

      default:
        break;
    }
  }

  async function activateBrowserTab(tabId) {
    try {
      const updatedTab = await api.tabs.update(tabId, { active: true });
      if (updatedTab && typeof updatedTab.windowId === 'number') {
        await api.windows.update(updatedTab.windowId, { focused: true });
      }
    } catch (_) {}
  }

  function emitJpegPacket(session, jpegBytes) {
    if (!isStreamConnected() || !streamWs) return;
    if (streamWs.bufferedAmount > MAX_WS_BUFFERED_BYTES) return;
    const seq = session.seq;
    session.seq = (session.seq + 1) >>> 0;
    const ts = nextMonotonicTimestampUs();
    const packet = packJpegWirePacket(
      session.tabId,
      seq,
      ts,
      session.viewportWidth,
      session.viewportHeight,
      jpegBytes
    );
    try {
      streamWs.send(packet.buffer);
    } catch (_) {}
  }

  function scheduleNextTick(session, delayMs) {
    if (session.stopped) return;
    if (session.timerId !== null) {
      clearTimeout(session.timerId);
    }
    session.timerId = setTimeout(() => {
      session.timerId = null;
      runCaptureTick(session);
    }, delayMs);
  }

  function triggerImmediateCaptureTick(session) {
    if (session.stopped || session.inFlight) return;
    scheduleNextTick(session, 0);
  }

  async function refreshTabDimensionsIfNeeded(session) {
    try {
      const tab = await api.tabs.get(session.tabId);
      if (!tab) return;
      let changed = false;
      if (typeof tab.width === 'number' && tab.width >= 64 && tab.width !== session.viewportWidth) {
        session.viewportWidth = tab.width;
        changed = true;
      }
      if (typeof tab.height === 'number' && tab.height >= 64 && tab.height !== session.viewportHeight) {
        session.viewportHeight = tab.height;
        changed = true;
      }
      if (tab.title && tab.title !== session.title) {
        session.title = tab.title;
        changed = true;
      }
      if (changed) {
        let host = session.urlHost;
        try {
          if (tab.url) host = new URL(tab.url).hostname || host;
        } catch (_) {}
        session.urlHost = host;
        sendControlJson({
          type: 'tab_updated',
          tabId: session.tabId,
          title: session.title,
          urlHost: session.urlHost,
          viewportWidth: session.viewportWidth,
          viewportHeight: session.viewportHeight
        });
      }
    } catch (_) {}
  }

  async function runCaptureTick(session) {
    if (session.stopped) return;
    if (!isStreamConnected()) {
      scheduleOrphanCaptureCleanup();
      scheduleNextTick(session, IDLE_CAPTURE_INTERVAL_MS);
      return;
    }
    if (streamWs && streamWs.bufferedAmount > MAX_WS_BUFFERED_BYTES) {
      scheduleNextTick(session, ACTIVE_CAPTURE_INTERVAL_MS);
      return;
    }

    session.inFlight = true;
    const tickStart = performance.now();
    try {
      session.tickCount += 1;
      if (session.tickCount % 6 === 0) {
        await refreshTabDimensionsIfNeeded(session);
      }

      const maxCssEdge = Math.max(1, session.viewportWidth, session.viewportHeight);
      const rawScale = Math.min(session.dpr || 2, MAX_LONG_EDGE_PX / maxCssEdge);
      const scale = Math.max(0.5, Math.min(2.0, rawScale));

      const dataUrl = await api.tabs.captureTab(session.tabId, {
        format: 'jpeg',
        quality: JPEG_QUALITY,
        scale
      });

      if (session.stopped) return;

      if (!session.forceSendNext && dataUrl === session.lastDataUrl) {
        session.unchangedCount += 1;
      } else {
        const commaIndex = dataUrl.indexOf(',');
        if (commaIndex > 0) {
          const jpegBytes = decodeBase64ToBytes(dataUrl.slice(commaIndex + 1));
          if (jpegBytes.byteLength > 0) {
            session.lastDataUrl = dataUrl;
            session.lastJpegBytes = jpegBytes;
            session.unchangedCount = 0;
            session.forceSendNext = false;
            emitJpegPacket(session, jpegBytes);
          }
        }
      }
    } catch (_) {
      // Tab may be mid-navigation or discarded; retry gently on next tick.
      session.unchangedCount += 1;
    } finally {
      session.inFlight = false;
    }

    if (session.stopped) return;
    const elapsed = performance.now() - tickStart;
    const targetInterval = session.unchangedCount >= UNCHANGED_BACKOFF_FRAMES
      ? IDLE_CAPTURE_INTERVAL_MS
      : ACTIVE_CAPTURE_INTERVAL_MS;
    const waitMs = Math.max(16, Math.round(targetInterval - elapsed));
    scheduleNextTick(session, waitMs);
  }

  function ensureCaptureSession(tabId, metadata) {
    let session = captureSessions.get(tabId);
    if (session && !session.stopped) {
      session.viewportWidth = metadata.viewportWidth || session.viewportWidth;
      session.viewportHeight = metadata.viewportHeight || session.viewportHeight;
      session.dpr = metadata.devicePixelRatio || session.dpr;
      session.title = metadata.title || session.title;
      session.urlHost = metadata.urlHost || session.urlHost;
      session.forceSendNext = true;
      triggerImmediateCaptureTick(session);
      return session;
    }

    session = {
      tabId,
      viewportWidth: metadata.viewportWidth || 1280,
      viewportHeight: metadata.viewportHeight || 800,
      dpr: metadata.devicePixelRatio || 2,
      title: metadata.title || '',
      urlHost: metadata.urlHost || '',
      seq: 0,
      lastDataUrl: '',
      lastJpegBytes: null,
      unchangedCount: 0,
      inFlight: false,
      forceSendNext: true,
      stopped: false,
      timerId: null,
      tickCount: 0
    };
    captureSessions.set(tabId, session);
    runCaptureTick(session);
    return session;
  }

  function stopCaptureSession(tabId) {
    const session = captureSessions.get(tabId);
    if (!session) return;
    session.stopped = true;
    if (session.timerId !== null) {
      clearTimeout(session.timerId);
      session.timerId = null;
    }
    session.lastDataUrl = '';
    session.lastJpegBytes = null;
    captureSessions.delete(tabId);
    runDeferredReloadIfIdle();
  }

  function stopAllCaptureSessions() {
    for (const tabId of Array.from(captureSessions.keys())) {
      stopCaptureSession(tabId);
    }
  }

  async function injectCropOverlayInTab(tabId) {
    if (api.scripting && typeof api.scripting.executeScript === 'function') {
      await api.scripting.executeScript({
        target: { tabId },
        files: ['crop-overlay.js']
      });
      return;
    }
    await api.tabs.executeScript(tabId, { file: 'crop-overlay.js' });
  }

  async function fallbackFullTabIfCapturable(tab) {
    try {
      const probeDataUrl = await api.tabs.captureTab(tab.id, {
        format: 'jpeg',
        quality: JPEG_QUALITY,
        scale: 1
      });
      if (!probeDataUrl || probeDataUrl.indexOf(',') <= 0) {
        flashBadge('N/A', '#FF9F0A', 3000);
        return;
      }

      const viewportWidth = Math.max(120, tab.width || 1280);
      const viewportHeight = Math.max(120, tab.height || 800);
      const title = tab.title || 'Browser Tab';
      let urlHost = '';
      if (tab.url) {
        try {
          urlHost = new URL(tab.url).hostname || '';
        } catch (_) {}
      }

      ensureCaptureSession(tab.id, {
        viewportWidth,
        viewportHeight,
        devicePixelRatio: 2,
        title,
        urlHost
      });

      sendControlJson({
        type: 'start_tab_pane',
        tabId: tab.id,
        browserBundleId: detectFallbackBrowserBundleId(),
        title,
        urlHost,
        cropRect: { x: 0, y: 0, width: 1, height: 1 },
        viewportWidth,
        viewportHeight
      });
    } catch (err) {
      console.warn('[PeekPane] Tab is restricted and cannot be captured:', err);
      flashBadge('N/A', '#FF9F0A', 3000);
    }
  }

  if (actionApi && actionApi.onClicked) {
    actionApi.onClicked.addListener((clickedTab) => {
      (async () => {
        let tab = clickedTab;
        if (!tab || typeof tab.id !== 'number' || tab.id < 0) {
          const activeTabs = await api.tabs.query({ active: true, currentWindow: true });
          tab = activeTabs && activeTabs[0];
        }
        if (!tab || typeof tab.id !== 'number' || tab.id < 0) {
          return;
        }

        Promise.resolve(actionApi.setBadgeText({ text: '' })).catch(() => {});

        const ready = await ensureBridgeReady({ allowBootstrap: true });
        if (!ready) {
          flashBadge('OFF', '#FF453A', 3000);
          return;
        }

        sendControlJson({
          type: 'crop_started',
          browserBundleId: detectFallbackBrowserBundleId()
        });

        try {
          await injectCropOverlayInTab(tab.id);
        } catch (_) {
          // Script-blocked tab (e.g. built-in PDF viewer, raw media URL, or internal page).
          await fallbackFullTabIfCapturable(tab);
        }
      })();
    });
  }

  api.runtime.onMessage.addListener((message, sender) => {
    if (!message || !sender || !sender.tab || typeof sender.tab.id !== 'number') {
      return;
    }
    const tabId = sender.tab.id;

    if (message.type === 'OVERLAY_CROP_CONFIRMED') {
      (async () => {
        const ready = await ensureBridgeReady({ allowBootstrap: true });
        if (!ready) {
          flashBadge('OFF', '#FF453A', 3000);
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, OVERLAY_SETTLE_MS));

        const viewportWidth = message.viewportWidth || sender.tab.width || 1280;
        const viewportHeight = message.viewportHeight || sender.tab.height || 800;
        const title = message.title || sender.tab.title || '';
        let urlHost = message.urlHost || '';
        if (!urlHost && sender.tab.url) {
          try {
            urlHost = new URL(sender.tab.url).hostname || '';
          } catch (_) {}
        }

        ensureCaptureSession(tabId, {
          viewportWidth,
          viewportHeight,
          devicePixelRatio: message.devicePixelRatio || 2,
          title,
          urlHost
        });

        sendControlJson({
          type: 'start_tab_pane',
          tabId,
          browserBundleId: detectFallbackBrowserBundleId(),
          title,
          urlHost,
          cropRect: message.cropRect || { x: 0, y: 0, width: 1, height: 1 },
          viewportWidth,
          viewportHeight
        });
      })();
    }
  });

  api.tabs.onRemoved.addListener((tabId) => {
    if (!captureSessions.has(tabId)) return;
    stopCaptureSession(tabId);
    sendControlJson({ type: 'tab_closed', tabId });
  });

  api.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    const session = captureSessions.get(tabId);
    if (!session || session.stopped) return;
    if (!changeInfo.title && !changeInfo.url && changeInfo.status !== 'complete') return;

    if (tab.title) session.title = tab.title;
    if (typeof tab.width === 'number' && tab.width >= 64) session.viewportWidth = tab.width;
    if (typeof tab.height === 'number' && tab.height >= 64) session.viewportHeight = tab.height;
    if (tab.url) {
      try {
        session.urlHost = new URL(tab.url).hostname || session.urlHost;
      } catch (_) {}
    }

    sendControlJson({
      type: 'tab_updated',
      tabId,
      title: session.title,
      urlHost: session.urlHost,
      viewportWidth: session.viewportWidth,
      viewportHeight: session.viewportHeight
    });
    session.forceSendNext = true;
    triggerImmediateCaptureTick(session);
  });

  if (api.tabs.onZoomChange && typeof api.tabs.onZoomChange.addListener === 'function') {
    api.tabs.onZoomChange.addListener((zoomChangeInfo) => {
      if (!zoomChangeInfo || typeof zoomChangeInfo.tabId !== 'number') return;
      const session = captureSessions.get(zoomChangeInfo.tabId);
      if (session && !session.stopped) {
        session.forceSendNext = true;
        triggerImmediateCaptureTick(session);
      }
    });
  }

  api.alarms.onAlarm.addListener((alarm) => {
    if (alarm && alarm.name === PROBE_ALARM_NAME) {
      ensureBridgeReady({ allowBootstrap: false }).catch(() => {});
    }
  });

  function initializeBridgeLifecycle() {
    api.alarms.create(PROBE_ALARM_NAME, { periodInMinutes: 0.5 });
    ensureBridgeReady({ allowBootstrap: false }).then((ok) => {
      if (!ok) {
        scheduleFastReconnect();
      }
    }).catch(() => {});
  }

  api.runtime.onInstalled.addListener(() => {
    initializeBridgeLifecycle();
  });

  api.runtime.onStartup.addListener(() => {
    initializeBridgeLifecycle();
  });

  initializeBridgeLifecycle();
})();
