(() => {
  'use strict';

  const NATIVE_HOST_NAME = 'com.peekpane.bridge';
  const PROTOCOL_VERSION = 1;
  const PROBE_ALARM_NAME = 'peekpane-bridge-probe';
  const STORAGE_INSTANCE_ID_KEY = 'peekpaneExtensionInstanceId';
  const STORAGE_LAST_BUNDLE_ID_KEY = 'peekpaneLastBrowserBundleId';
  const STORAGE_LAST_AUTO_RELOAD_KEY = 'peekpaneLastAutoReloadTargetVersion';

  /** @type {WebSocket | null} */
  let controlWs = null;
  let controlWsAuthenticated = false;
  let currentEndpoint = null;
  let cachedInstanceId = null;
  let cachedBrowserBundleId = '';
  let pendingAutoReloadVersion = null;
  let badgeResetTimer = null;
  let viewportPollInterval = null;

  /**
   * Active captured tabs in this browser profile:
   * tabId -> { paneCount: number, viewportWidth: number, viewportHeight: number, title: string }
   * @type {Map<number, { paneCount: number, viewportWidth: number, viewportHeight: number, title: string }>}
   */
  const capturedTabs = new Map();

  function getManifestVersion() {
    return chrome.runtime.getManifest().version || '1.0.0';
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

  async function getOrCreateExtensionInstanceId() {
    if (cachedInstanceId) return cachedInstanceId;
    const stored = await chrome.storage.local.get([STORAGE_INSTANCE_ID_KEY, STORAGE_LAST_BUNDLE_ID_KEY]);
    if (stored[STORAGE_LAST_BUNDLE_ID_KEY] && !cachedBrowserBundleId) {
      cachedBrowserBundleId = stored[STORAGE_LAST_BUNDLE_ID_KEY];
    }
    if (stored[STORAGE_INSTANCE_ID_KEY]) {
      cachedInstanceId = stored[STORAGE_INSTANCE_ID_KEY];
      return cachedInstanceId;
    }
    const generated = crypto.randomUUID();
    await chrome.storage.local.set({ [STORAGE_INSTANCE_ID_KEY]: generated });
    cachedInstanceId = generated;
    return generated;
  }

  async function detectFallbackBrowserBundleId() {
    if (cachedBrowserBundleId) return cachedBrowserBundleId;
    try {
      if (navigator.brave && typeof navigator.brave.isBrave === 'function') {
        const isBrave = await navigator.brave.isBrave();
        if (isBrave) return 'com.brave.Browser';
      }
    } catch (_) {}

    const ua = navigator.userAgent || '';
    if (ua.includes('Edg/')) return 'com.microsoft.edgemac';
    if (ua.includes('Vivaldi/')) return 'com.vivaldi.Vivaldi';
    return 'com.google.Chrome';
  }

  async function discoverActionShortcut() {
    try {
      const commands = await chrome.commands.getAll();
      const executeCmd = commands.find((cmd) => cmd.name === '_execute_action');
      return (executeCmd && executeCmd.shortcut) ? executeCmd.shortcut : '';
    } catch (_) {
      return '';
    }
  }

  function sendNativeHostMessage(requestObj) {
    return new Promise((resolve) => {
      chrome.runtime.sendNativeMessage(NATIVE_HOST_NAME, requestObj, (response) => {
        if (chrome.runtime.lastError || !response) {
          resolve({
            ok: false,
            running: false,
            error: chrome.runtime.lastError ? chrome.runtime.lastError.message : 'No response from native host'
          });
          return;
        }
        resolve(response);
      });
    });
  }

  async function rememberCallerBundleId(bundleId) {
    if (!bundleId || typeof bundleId !== 'string') return;
    if (cachedBrowserBundleId !== bundleId) {
      cachedBrowserBundleId = bundleId;
      await chrome.storage.local.set({ [STORAGE_LAST_BUNDLE_ID_KEY]: bundleId });
    }
  }

  async function ensureOffscreenDocument() {
    if (chrome.runtime.getContexts) {
      const existing = await chrome.runtime.getContexts({
        contextTypes: ['OFFSCREEN_DOCUMENT']
      });
      if (existing && existing.length > 0) {
        return;
      }
    }
    try {
      await chrome.offscreen.createDocument({
        url: 'offscreen.html',
        reasons: ['USER_MEDIA'],
        justification: 'Capture and H.264-encode selected browser tab frames for PeekPane floating panes'
      });
    } catch (err) {
      const message = String(err && err.message ? err.message : err);
      if (!message.includes('Only a single offscreen')) {
        throw err;
      }
    }
  }

  async function syncEndpointToOffscreen() {
    if (!currentEndpoint || !currentEndpoint.wsPort || !currentEndpoint.token) return;
    if (chrome.runtime.getContexts) {
      const existing = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
      if (!existing || existing.length === 0) return;
    }
    const instanceId = await getOrCreateExtensionInstanceId();
    const browserBundleId = cachedBrowserBundleId || await detectFallbackBrowserBundleId();
    try {
      await chrome.runtime.sendMessage({
        type: 'OFFSCREEN_CONFIGURE_ENDPOINT',
        wsPort: currentEndpoint.wsPort,
        token: currentEndpoint.token,
        extensionInstanceId: instanceId,
        browserBundleId,
        extensionVersion: getManifestVersion()
      });
    } catch (_) {}
  }

  function sendControlJson(payload) {
    if (controlWs && controlWs.readyState === WebSocket.OPEN && controlWsAuthenticated) {
      try {
        controlWs.send(JSON.stringify(payload));
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  function connectControlWebSocket(endpoint) {
    return new Promise(async (resolve) => {
      if (
        controlWs &&
        controlWs.readyState === WebSocket.OPEN &&
        controlWsAuthenticated &&
        currentEndpoint &&
        currentEndpoint.wsPort === endpoint.wsPort &&
        currentEndpoint.token === endpoint.token
      ) {
        resolve(true);
        return;
      }

      currentEndpoint = endpoint;
      if (controlWs) {
        try {
          controlWs.close();
        } catch (_) {}
        controlWs = null;
        controlWsAuthenticated = false;
      }

      const instanceId = await getOrCreateExtensionInstanceId();
      const browserBundleId = cachedBrowserBundleId || await detectFallbackBrowserBundleId();
      const actionShortcut = await discoverActionShortcut();

      let settled = false;
      const finish = (ok) => {
        if (settled) return;
        settled = true;
        resolve(ok);
      };

      const timeoutId = setTimeout(() => finish(false), 4000);
      const ws = new WebSocket(`ws://127.0.0.1:${endpoint.wsPort}`);
      controlWs = ws;

      ws.onopen = () => {
        if (controlWs !== ws) return;
        ws.send(JSON.stringify({
          type: 'hello',
          protocolVersion: PROTOCOL_VERSION,
          role: 'control',
          extensionInstanceId: instanceId,
          browserBundleId,
          extensionVersion: getManifestVersion(),
          actionShortcut,
          token: endpoint.token
        }));
      };

      ws.onmessage = async (event) => {
        if (controlWs !== ws || typeof event.data !== 'string') return;
        let msg = null;
        try {
          msg = JSON.parse(event.data);
        } catch (_) {
          return;
        }
        if (!msg || typeof msg.type !== 'string') return;

        if (msg.type === 'hello_ack') {
          clearTimeout(timeoutId);
          controlWsAuthenticated = true;
          await syncEndpointToOffscreen();
          await maybeHandleStagedAutoReload(msg.stagedExtensionVersion);
          finish(true);
          return;
        }

        handleInboundServerControlMessage(msg);
      };

      ws.onclose = () => {
        clearTimeout(timeoutId);
        if (controlWs === ws) {
          controlWs = null;
          controlWsAuthenticated = false;
        }
        finish(false);
      };

      ws.onerror = () => {
        try {
          ws.close();
        } catch (_) {}
      };
    });
  }

  async function maybeHandleStagedAutoReload(stagedVersion) {
    if (!stagedVersion || !isSemverGreater(stagedVersion, getManifestVersion())) {
      return;
    }
    const stored = await chrome.storage.local.get([STORAGE_LAST_AUTO_RELOAD_KEY]);
    if (stored[STORAGE_LAST_AUTO_RELOAD_KEY] === stagedVersion) {
      // Loop guard: already attempted auto-reload for this target version once.
      return;
    }
    if (capturedTabs.size > 0) {
      pendingAutoReloadVersion = stagedVersion;
      return;
    }
    await chrome.storage.local.set({ [STORAGE_LAST_AUTO_RELOAD_KEY]: stagedVersion });
    chrome.runtime.reload();
  }

  async function runDeferredReloadIfIdle() {
    if (!pendingAutoReloadVersion || capturedTabs.size > 0) return;
    const target = pendingAutoReloadVersion;
    pendingAutoReloadVersion = null;
    await maybeHandleStagedAutoReload(target);
  }

  function handleInboundServerControlMessage(msg) {
    switch (msg.type) {
      case 'ping':
        sendControlJson({ type: 'pong' });
        break;

      case 'highlight_action_badge':
        flashBadgeText(null, '●', '#0A84FF', 8000);
        break;

      case 'activate_tab':
        if (typeof msg.tabId === 'number') {
          chrome.tabs.get(msg.tabId, (tab) => {
            if (chrome.runtime.lastError || !tab) return;
            chrome.tabs.update(msg.tabId, { active: true }, () => {
              void chrome.runtime.lastError;
            });
            if (typeof tab.windowId === 'number') {
              chrome.windows.update(tab.windowId, { focused: true }, () => {
                void chrome.runtime.lastError;
              });
            }
          });
        }
        break;

      case 'request_keyframe':
        if (typeof msg.tabId === 'number') {
          chrome.runtime.sendMessage({
            type: 'OFFSCREEN_FORCE_KEYFRAME',
            tabId: msg.tabId
          }).catch(() => {});
        }
        break;

      case 'stop_tab_capture':
        if (typeof msg.tabId === 'number') {
          capturedTabs.delete(msg.tabId);
          syncViewportPollLoop();
          chrome.runtime.sendMessage({
            type: 'OFFSCREEN_STOP_TAB_STREAM',
            tabId: msg.tabId
          }).catch(() => {});
          runDeferredReloadIfIdle();
        }
        break;

      default:
        break;
    }
  }

  function flashBadgeText(tabId, text, colorHex, durationMs) {
    clearTimeout(badgeResetTimer);
    const details = tabId ? { text, tabId } : { text };
    const colorDetails = tabId ? { color: colorHex, tabId } : { color: colorHex };
    chrome.action.setBadgeBackgroundColor(colorDetails, () => void chrome.runtime.lastError);
    chrome.action.setBadgeText(details, () => void chrome.runtime.lastError);
    badgeResetTimer = setTimeout(() => {
      const clearDetails = tabId ? { text: '', tabId } : { text: '' };
      chrome.action.setBadgeText(clearDetails, () => void chrome.runtime.lastError);
    }, durationMs);
  }

  async function probeAndMaybeConnect() {
    const resp = await sendNativeHostMessage({ type: 'probe' });
    if (resp && resp.callerBundleIdentifier) {
      await rememberCallerBundleId(resp.callerBundleIdentifier);
    }
    if (resp && resp.ok && resp.running && resp.wsPort && resp.token) {
      await connectControlWebSocket(resp);
    }
  }

  async function bootstrapAndConnect() {
    if (controlWs && controlWs.readyState === WebSocket.OPEN && controlWsAuthenticated) {
      return true;
    }
    let resp = await sendNativeHostMessage({ type: 'bootstrap' });
    if ((!resp || !resp.ok || !resp.running) && (!resp || !resp.wsPort)) {
      await new Promise((r) => setTimeout(r, 300));
      resp = await sendNativeHostMessage({ type: 'bootstrap' });
    }
    if (resp && resp.callerBundleIdentifier) {
      await rememberCallerBundleId(resp.callerBundleIdentifier);
    }
    if (!resp || !resp.ok || !resp.running || !resp.wsPort || !resp.token) {
      return false;
    }
    return connectControlWebSocket(resp);
  }

  async function hasExistingOffscreenStream(tabId) {
    try {
      if (chrome.runtime.getContexts) {
        const existing = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
        if (!existing || existing.length === 0) return false;
      }
      const reply = await chrome.runtime.sendMessage({
        type: 'OFFSCREEN_HAS_ACTIVE_STREAM',
        tabId
      });
      return Boolean(reply && reply.active);
    } catch (_) {
      return false;
    }
  }

  async function redeemStreamInOffscreen(tab, streamId) {
    await ensureOffscreenDocument();
    await syncEndpointToOffscreen();
    const reply = await chrome.runtime.sendMessage({
      type: 'OFFSCREEN_START_TAB_STREAM',
      tabId: tab.id,
      streamId,
      viewportWidth: tab.width || 1280,
      viewportHeight: tab.height || 800
    });
    return Boolean(reply && reply.ok);
  }

  function syncViewportPollLoop() {
    if (capturedTabs.size === 0) {
      if (viewportPollInterval !== null) {
        clearInterval(viewportPollInterval);
        viewportPollInterval = null;
      }
      return;
    }
    if (viewportPollInterval === null) {
      viewportPollInterval = setInterval(() => {
        refreshAllCapturedTabViewports();
      }, 2000);
    }
  }

  function refreshAllCapturedTabViewports() {
    for (const [tabId, entry] of capturedTabs.entries()) {
      chrome.tabs.get(tabId, (tab) => {
        if (chrome.runtime.lastError || !tab) return;
        const nextW = tab.width || entry.viewportWidth;
        const nextH = tab.height || entry.viewportHeight;
        const nextTitle = tab.title || entry.title;
        if (nextW !== entry.viewportWidth || nextH !== entry.viewportHeight || nextTitle !== entry.title) {
          entry.viewportWidth = nextW;
          entry.viewportHeight = nextH;
          entry.title = nextTitle;
          chrome.runtime.sendMessage({
            type: 'OFFSCREEN_UPDATE_VIEWPORT',
            tabId,
            viewportWidth: nextW,
            viewportHeight: nextH
          }).catch(() => {});
          sendControlJson({
            type: 'tab_updated',
            tabId,
            title: nextTitle,
            viewportWidth: nextW,
            viewportHeight: nextH
          });
        }
      });
    }
  }

  async function injectCropOverlayOrFallbackFullTab(tab) {
    const browserBundleId = cachedBrowserBundleId || await detectFallbackBrowserBundleId();
    sendControlJson({ type: 'crop_started', browserBundleId });

    try {
      await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        files: ['crop-overlay.js']
      });
    } catch (_) {
      // Script-blocked but capturable tab (e.g. built-in PDF viewer, raw media URL): float full viewport immediately.
      const vw = Math.max(120, tab.width || 1280);
      const vh = Math.max(120, tab.height || 800);
      const existing = capturedTabs.get(tab.id) || {
        paneCount: 0,
        viewportWidth: vw,
        viewportHeight: vh,
        title: tab.title || ''
      };
      existing.paneCount += 1;
      existing.viewportWidth = vw;
      existing.viewportHeight = vh;
      capturedTabs.set(tab.id, existing);
      syncViewportPollLoop();

      await syncEndpointToOffscreen();
      await chrome.runtime.sendMessage({
        type: 'OFFSCREEN_CONFIRM_CROP',
        tabId: tab.id,
        viewportWidth: vw,
        viewportHeight: vh,
        skipSettleDelay: true
      }).catch(() => {});

      sendControlJson({
        type: 'start_tab_pane',
        browserBundleId,
        tabId: tab.id,
        title: tab.title || 'Browser Tab',
        urlHost: '',
        cropRect: { x: 0, y: 0, width: 1, height: 1 },
        viewportWidth: vw,
        viewportHeight: vh
      });
    }
  }

  // --- Top-level MV3 Event Listeners ---

  chrome.runtime.onInstalled.addListener(() => {
    chrome.alarms.create(PROBE_ALARM_NAME, { periodInMinutes: 5 });
    probeAndMaybeConnect();
  });

  chrome.runtime.onStartup.addListener(() => {
    chrome.alarms.create(PROBE_ALARM_NAME, { periodInMinutes: 5 });
    probeAndMaybeConnect();
  });

  chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === PROBE_ALARM_NAME) {
      if (!controlWs || controlWs.readyState !== WebSocket.OPEN) {
        probeAndMaybeConnect();
      }
    }
  });

  chrome.action.onClicked.addListener((tab) => {
    if (!tab || typeof tab.id !== 'number') return;

    // Clear any Flow 2 highlight badge immediately on click.
    chrome.action.setBadgeText({ text: '' }, () => void chrome.runtime.lastError);

    // MUST be the very first synchronous call inside action.onClicked to preserve the activeTab user gesture.
    chrome.tabCapture.getMediaStreamId({ targetTabId: tab.id }, async (streamId) => {
      const captureErr = chrome.runtime.lastError;
      if (captureErr || !streamId) {
        const alreadyCapturing = await hasExistingOffscreenStream(tab.id);
        if (!alreadyCapturing) {
          flashBadgeText(tab.id, 'N/A', '#D97706', 2000);
          return;
        }
        const connected = await bootstrapAndConnect();
        if (!connected) {
          flashBadgeText(tab.id, 'ERR', '#DC2626', 2500);
          return;
        }
        await syncEndpointToOffscreen();
        await injectCropOverlayOrFallbackFullTab(tab);
        return;
      }

      const [redeemed, connected] = await Promise.all([
        redeemStreamInOffscreen(tab, streamId),
        bootstrapAndConnect()
      ]);

      if (!redeemed || !connected) {
        if (redeemed && !capturedTabs.has(tab.id)) {
          chrome.runtime.sendMessage({
            type: 'OFFSCREEN_STOP_TAB_STREAM',
            tabId: tab.id
          }).catch(() => {});
        }
        flashBadgeText(tab.id, 'ERR', '#DC2626', 2500);
        return;
      }

      await syncEndpointToOffscreen();
      await injectCropOverlayOrFallbackFullTab(tab);
    });
  });

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (!msg || typeof msg.type !== 'string') return false;

    if (msg.type === 'OVERLAY_CROP_CONFIRMED') {
      const tabId = sender && sender.tab && typeof sender.tab.id === 'number' ? sender.tab.id : null;
      if (tabId === null) return false;

      (async () => {
        const connected = await bootstrapAndConnect();
        if (!connected) {
          if (!capturedTabs.has(tabId)) {
            chrome.runtime.sendMessage({ type: 'OFFSCREEN_STOP_TAB_STREAM', tabId }).catch(() => {});
          }
          sendResponse({ ok: false });
          return;
        }

        const vw = Math.max(120, msg.viewportWidth || (sender.tab && sender.tab.width) || 1280);
        const vh = Math.max(120, msg.viewportHeight || (sender.tab && sender.tab.height) || 800);
        const title = msg.title || (sender.tab && sender.tab.title) || 'Browser Tab';
        const existing = capturedTabs.get(tabId) || {
          paneCount: 0,
          viewportWidth: vw,
          viewportHeight: vh,
          title
        };
        const wasAlreadyStreaming = existing.paneCount > 0;
        existing.paneCount += 1;
        existing.viewportWidth = vw;
        existing.viewportHeight = vh;
        existing.title = title;
        capturedTabs.set(tabId, existing);
        syncViewportPollLoop();

        await syncEndpointToOffscreen();
        await chrome.runtime.sendMessage({
          type: 'OFFSCREEN_CONFIRM_CROP',
          tabId,
          viewportWidth: vw,
          viewportHeight: vh,
          skipSettleDelay: wasAlreadyStreaming
        }).catch(() => {});

        const browserBundleId = cachedBrowserBundleId || await detectFallbackBrowserBundleId();
        sendControlJson({
          type: 'start_tab_pane',
          browserBundleId,
          tabId,
          title,
          urlHost: msg.urlHost || '',
          cropRect: msg.cropRect || { x: 0, y: 0, width: 1, height: 1 },
          viewportWidth: vw,
          viewportHeight: vh
        });
        sendResponse({ ok: true });
      })();
      return true;
    }

    if (msg.type === 'OVERLAY_CROP_CANCELLED') {
      const tabId = sender && sender.tab && typeof sender.tab.id === 'number' ? sender.tab.id : null;
      if (tabId !== null) {
        const existing = capturedTabs.get(tabId);
        if (!existing || existing.paneCount === 0) {
          capturedTabs.delete(tabId);
          syncViewportPollLoop();
          chrome.runtime.sendMessage({
            type: 'OFFSCREEN_STOP_TAB_STREAM',
            tabId
          }).catch(() => {});
        }
      }
      sendResponse({ ok: true });
      return false;
    }

    if (msg.type === 'OFFSCREEN_CAPTURE_ENDED') {
      if (typeof msg.tabId === 'number') {
        capturedTabs.delete(msg.tabId);
        syncViewportPollLoop();
        sendControlJson({
          type: 'capture_stopped',
          tabId: msg.tabId,
          reason: msg.reason || 'Tab capture ended'
        });
        runDeferredReloadIfIdle();
      }
      sendResponse({ ok: true });
      return false;
    }

    return false;
  });

  chrome.windows.onBoundsChanged.addListener(() => {
    if (capturedTabs.size > 0) {
      refreshAllCapturedTabViewports();
    }
  });

  chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    const entry = capturedTabs.get(tabId);
    if (!entry) return;
    if (changeInfo.title || changeInfo.status === 'complete') {
      const nextW = (tab && tab.width) || entry.viewportWidth;
      const nextH = (tab && tab.height) || entry.viewportHeight;
      const nextTitle = (tab && tab.title) || changeInfo.title || entry.title;
      entry.viewportWidth = nextW;
      entry.viewportHeight = nextH;
      entry.title = nextTitle;
      chrome.runtime.sendMessage({
        type: 'OFFSCREEN_UPDATE_VIEWPORT',
        tabId,
        viewportWidth: nextW,
        viewportHeight: nextH
      }).catch(() => {});
      sendControlJson({
        type: 'tab_updated',
        tabId,
        title: nextTitle,
        viewportWidth: nextW,
        viewportHeight: nextH
      });
    }
  });

  chrome.tabs.onRemoved.addListener((tabId) => {
    if (!capturedTabs.has(tabId)) return;
    capturedTabs.delete(tabId);
    syncViewportPollLoop();
    chrome.runtime.sendMessage({
      type: 'OFFSCREEN_STOP_TAB_STREAM',
      tabId
    }).catch(() => {});
    sendControlJson({
      type: 'tab_closed',
      tabId
    });
    runDeferredReloadIfIdle();
  });
})();
