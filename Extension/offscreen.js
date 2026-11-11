(() => {
  'use strict';

  const PROTOCOL_VERSION = 1;
  const HEADER_BYTES = 28;
  const MAX_LONG_EDGE = 2560;
  const TARGET_FPS = 24;
  const KEYFRAME_INTERVAL_FRAMES = 96;
  const OVERLAY_SETTLE_MS = 80;
  const BACKPRESSURE_MAX_BUFFERED_BYTES = 512000;
  const BACKPRESSURE_MAX_ENCODER_QUEUE = 2;
  const CODEC_CANDIDATES = ['avc1.640033', 'avc1.640032', 'avc1.4d0033', 'avc1.4d0032'];

  /** @type {Map<number, TabPipeline>} */
  const pipelines = new Map();

  let endpointConfig = null;
  /** @type {WebSocket | null} */
  let streamWs = null;
  let streamWsAuthenticated = false;
  let reconnectTimer = null;
  let disconnectShutdownTimer = null;
  let globalMonotonicTimestampUs = 0;

  function nextMonotonicTimestampUs(candidateUs) {
    const base = typeof candidateUs === 'number' && Number.isFinite(candidateUs) && candidateUs > 0
      ? Math.floor(candidateUs)
      : Math.floor(performance.now() * 1000);
    if (base <= globalMonotonicTimestampUs) {
      globalMonotonicTimestampUs += 1000;
    } else {
      globalMonotonicTimestampUs = base;
    }
    return globalMonotonicTimestampUs;
  }

  function clampEvenDimension(rawValue, fallback) {
    const n = Number.isFinite(rawValue) && rawValue > 0 ? Math.round(rawValue) : fallback;
    return Math.max(64, n & ~1);
  }

  function computeMaxCaptureSize(viewportW, viewportH) {
    const rawW = Math.max(128, (viewportW || 1280) * 2);
    const rawH = Math.max(128, (viewportH || 800) * 2);
    const scale = Math.min(1, MAX_LONG_EDGE / Math.max(rawW, rawH));
    return {
      maxWidth: clampEvenDimension(rawW * scale, 1920),
      maxHeight: clampEvenDimension(rawH * scale, 1200)
    };
  }

  function computeBitrate(width, height) {
    const raw = Math.round(width * height * TARGET_FPS * 0.12);
    return Math.max(2000000, Math.min(10000000, raw));
  }

  function isStreamSocketWritable() {
    return streamWs !== null && streamWs.readyState === WebSocket.OPEN && streamWsAuthenticated;
  }

  function ensureStreamSocket() {
    if (!endpointConfig || !endpointConfig.wsPort || !endpointConfig.token) {
      return;
    }
    if (streamWs && (streamWs.readyState === WebSocket.OPEN || streamWs.readyState === WebSocket.CONNECTING)) {
      return;
    }

    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    streamWsAuthenticated = false;

    const ws = new WebSocket(`ws://127.0.0.1:${endpointConfig.wsPort}`);
    ws.binaryType = 'arraybuffer';
    streamWs = ws;

    ws.onopen = () => {
      if (streamWs !== ws) return;
      clearTimeout(disconnectShutdownTimer);
      disconnectShutdownTimer = null;
      ws.send(JSON.stringify({
        type: 'hello',
        protocolVersion: PROTOCOL_VERSION,
        role: 'stream',
        extensionInstanceId: endpointConfig.extensionInstanceId,
        browserBundleId: endpointConfig.browserBundleId || '',
        extensionVersion: endpointConfig.extensionVersion || '1.0.0',
        actionShortcut: '',
        token: endpointConfig.token
      }));
    };

    ws.onmessage = (event) => {
      if (streamWs !== ws || typeof event.data !== 'string') return;
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'hello_ack') {
          streamWsAuthenticated = true;
          for (const pipeline of pipelines.values()) {
            pipeline.forceImmediateKeyframe();
          }
        }
      } catch (_) {
        // Ignore non-JSON frames.
      }
    };

    ws.onclose = () => {
      if (streamWs !== ws) return;
      streamWs = null;
      streamWsAuthenticated = false;

      if (pipelines.size === 0) {
        return;
      }

      // If PeekPane quit, shut down active MediaStreamTracks promptly so Chrome's blue tab indicator turns off.
      clearTimeout(disconnectShutdownTimer);
      disconnectShutdownTimer = setTimeout(() => {
        if (!isStreamSocketWritable()) {
          stopAllPipelines('PeekPane bridge disconnected');
        }
      }, 1500);

      reconnectTimer = setTimeout(() => {
        if (pipelines.size > 0) {
          ensureStreamSocket();
        }
      }, 400);
    };

    ws.onerror = () => {
      try {
        ws.close();
      } catch (_) {
        // Ignore close errors.
      }
    };
  }

  function stopAllPipelines(reason) {
    const activeTabIds = Array.from(pipelines.keys());
    for (const tabId of activeTabIds) {
      const pipeline = pipelines.get(tabId);
      pipelines.delete(tabId);
      if (pipeline) {
        pipeline.stop(false);
      }
      chrome.runtime.sendMessage({
        type: 'OFFSCREEN_CAPTURE_ENDED',
        tabId,
        reason
      }).catch(() => {});
    }
  }

  class TabPipeline {
    constructor(tabId, viewportW, viewportH) {
      this.tabId = tabId >>> 0;
      this.viewportWidth = Math.max(64, Math.min(65535, Math.round(viewportW || 1280)));
      this.viewportHeight = Math.max(64, Math.min(65535, Math.round(viewportH || 800)));
      this.state = 'awaiting_crop'; // 'awaiting_crop' | 'settling' | 'streaming' | 'stopped'

      this.mediaStream = null;
      this.videoTrack = null;
      this.reader = null;
      this.encoder = null;
      this.selectedCodec = null;
      this.configuredWidth = 0;
      this.configuredHeight = 0;
      this.cachedAvcC = null;

      this.lastVideoFrame = null;
      this.sequenceNumber = 0;
      this.framesSinceKeyframe = 0;
      this.needsKeyframe = true;
      this.settleTimer = null;
      this.catchUpTimer = null;
    }

    async startWithStreamId(streamId) {
      const { maxWidth, maxHeight } = computeMaxCaptureSize(this.viewportWidth, this.viewportHeight);
      this.mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: {
          mandatory: {
            chromeMediaSource: 'tab',
            chromeMediaSourceId: streamId,
            maxWidth,
            maxHeight,
            maxFrameRate: TARGET_FPS
          }
        }
      });

      const tracks = this.mediaStream.getVideoTracks();
      if (!tracks.length) {
        throw new Error('No video track returned by tabCapture');
      }
      this.videoTrack = tracks[0];
      this.videoTrack.addEventListener('ended', () => {
        if (this.state === 'stopped') return;
        pipelines.delete(this.tabId);
        this.stop(false);
        chrome.runtime.sendMessage({
          type: 'OFFSCREEN_CAPTURE_ENDED',
          tabId: this.tabId,
          reason: 'Tab sharing stopped in browser'
        }).catch(() => {});
      });

      const processor = new MediaStreamTrackProcessor({ track: this.videoTrack });
      this.reader = processor.readable.getReader();
      this.pumpFramesLoop();
    }

    updateViewport(width, height) {
      if (width >= 64) {
        this.viewportWidth = Math.min(65535, Math.round(width));
      }
      if (height >= 64) {
        this.viewportHeight = Math.min(65535, Math.round(height));
      }
    }

    confirmCrop(skipSettleDelay) {
      if (this.state === 'stopped') return;
      ensureStreamSocket();

      if (this.state === 'streaming') {
        this.forceImmediateKeyframe();
        return;
      }

      clearTimeout(this.settleTimer);
      if (skipSettleDelay) {
        this.state = 'streaming';
        this.needsKeyframe = true;
        this.forceImmediateKeyframe();
        return;
      }

      this.state = 'settling';
      this.settleTimer = setTimeout(() => {
        if (this.state !== 'settling') return;
        this.state = 'streaming';
        this.needsKeyframe = true;
        this.forceImmediateKeyframe();
      }, OVERLAY_SETTLE_MS);
    }

    forceImmediateKeyframe() {
      if (this.state !== 'streaming' || !this.lastVideoFrame) {
        this.needsKeyframe = true;
        return;
      }
      this.needsKeyframe = true;
      const cloned = new VideoFrame(this.lastVideoFrame, {
        timestamp: nextMonotonicTimestampUs()
      });
      this.encodeFrame(cloned, true).catch(() => {
        try {
          cloned.close();
        } catch (_) {}
      });
    }

    replaceLastVideoFrame(incomingFrame) {
      const cloned = incomingFrame.clone();
      if (this.lastVideoFrame) {
        try {
          this.lastVideoFrame.close();
        } catch (_) {}
      }
      this.lastVideoFrame = cloned;
    }

    async pumpFramesLoop() {
      try {
        while (this.state !== 'stopped' && this.reader) {
          const { value: frame, done } = await this.reader.read();
          if (done || !frame) break;

          if (this.state === 'stopped') {
            frame.close();
            break;
          }

          this.replaceLastVideoFrame(frame);

          if (this.state !== 'streaming') {
            // Drain incoming frames while awaiting crop or settling post-overlay unmount.
            frame.close();
            continue;
          }

          if (this.isCongested()) {
            frame.close();
            this.scheduleCatchUpEncode();
            continue;
          }

          const stampedFrame = new VideoFrame(frame, {
            timestamp: nextMonotonicTimestampUs(frame.timestamp)
          });
          frame.close();
          await this.encodeFrame(stampedFrame, false);
        }
      } catch (_) {
        // Stream reader terminated.
      }
    }

    isCongested() {
      if (!isStreamSocketWritable()) return true;
      if (streamWs && streamWs.bufferedAmount > BACKPRESSURE_MAX_BUFFERED_BYTES) return true;
      if (this.encoder && this.encoder.encodeQueueSize > BACKPRESSURE_MAX_ENCODER_QUEUE) return true;
      return false;
    }

    scheduleCatchUpEncode() {
      if (this.catchUpTimer) return;
      this.catchUpTimer = setTimeout(() => {
        this.catchUpTimer = null;
        if (this.state !== 'streaming' || !this.lastVideoFrame) return;
        if (this.isCongested()) {
          this.scheduleCatchUpEncode();
          return;
        }
        const catchUpFrame = new VideoFrame(this.lastVideoFrame, {
          timestamp: nextMonotonicTimestampUs()
        });
        this.encodeFrame(catchUpFrame, false).catch(() => {
          try {
            catchUpFrame.close();
          } catch (_) {}
        });
      }, 60);
    }

    async ensureEncoderConfigured(evenWidth, evenHeight) {
      if (
        this.encoder &&
        this.encoder.state === 'configured' &&
        this.configuredWidth === evenWidth &&
        this.configuredHeight === evenHeight
      ) {
        return true;
      }

      if (!this.encoder || this.encoder.state === 'closed') {
        this.encoder = new VideoEncoder({
          output: (chunk, metadata) => this.handleEncodedChunk(chunk, metadata),
          error: () => {
            this.encoder = null;
            this.configuredWidth = 0;
            this.configuredHeight = 0;
            this.needsKeyframe = true;
          }
        });
      }

      const bitrate = computeBitrate(evenWidth, evenHeight);
      let chosenConfig = null;

      for (const codec of CODEC_CANDIDATES) {
        const candidate = {
          codec,
          width: evenWidth,
          height: evenHeight,
          bitrate,
          framerate: TARGET_FPS,
          hardwareAcceleration: 'prefer-hardware',
          latencyMode: 'realtime',
          avc: { format: 'avc' }
        };
        try {
          const support = await VideoEncoder.isConfigSupported(candidate);
          if (support.supported) {
            chosenConfig = support.config || candidate;
            this.selectedCodec = codec;
            break;
          }
        } catch (_) {
          // Try next H.264 profile/level candidate.
        }
      }

      if (!chosenConfig) {
        return false;
      }

      this.encoder.configure(chosenConfig);
      this.configuredWidth = evenWidth;
      this.configuredHeight = evenHeight;
      this.needsKeyframe = true;
      return true;
    }

    async encodeFrame(frame, forceKey) {
      try {
        if (this.state !== 'streaming') {
          return;
        }
        const evenW = clampEvenDimension(frame.displayWidth || frame.codedWidth, 1280);
        const evenH = clampEvenDimension(frame.displayHeight || frame.codedHeight, 720);

        const ready = await this.ensureEncoderConfigured(evenW, evenH);
        if (!ready || !this.encoder || this.encoder.state !== 'configured') {
          return;
        }

        const keyFrame = Boolean(
          forceKey ||
          this.needsKeyframe ||
          this.framesSinceKeyframe >= KEYFRAME_INTERVAL_FRAMES
        );
        this.encoder.encode(frame, { keyFrame });
        if (keyFrame) {
          this.needsKeyframe = false;
          this.framesSinceKeyframe = 0;
        } else {
          this.framesSinceKeyframe += 1;
        }
      } finally {
        try {
          frame.close();
        } catch (_) {}
      }
    }

    handleEncodedChunk(chunk, metadata) {
      if (this.state === 'stopped') return;

      const desc = metadata && metadata.decoderConfig && metadata.decoderConfig.description;
      if (desc) {
        this.cachedAvcC = desc instanceof Uint8Array
          ? new Uint8Array(desc)
          : new Uint8Array(desc instanceof ArrayBuffer ? desc : desc.buffer, desc.byteOffset || 0, desc.byteLength);
      }

      const isKeyframe = chunk.type === 'key';
      if (isKeyframe && (!this.cachedAvcC || this.cachedAvcC.byteLength === 0)) {
        this.needsKeyframe = true;
        return;
      }

      if (!isStreamSocketWritable()) {
        this.needsKeyframe = true;
        return;
      }

      const avcCBytes = isKeyframe ? this.cachedAvcC : null;
      const avcCLen = avcCBytes ? avcCBytes.byteLength : 0;
      const totalLen = HEADER_BYTES + avcCLen + chunk.byteLength;
      const buffer = new ArrayBuffer(totalLen);
      const view = new DataView(buffer);
      const outBytes = new Uint8Array(buffer);

      const seq = this.sequenceNumber >>> 0;
      this.sequenceNumber = (this.sequenceNumber + 1) >>> 0;
      const tsBig = BigInt(Math.max(0, Math.floor(chunk.timestamp)));
      const flags = (isKeyframe ? 1 : 0) | (avcCLen > 0 ? 2 : 0);

      view.setUint8(0, 0x50);
      view.setUint8(1, 0x50);
      view.setUint8(2, PROTOCOL_VERSION);
      view.setUint8(3, flags);
      view.setUint32(4, this.tabId, false);
      view.setUint32(8, seq, false);
      view.setBigUint64(12, tsBig, false);
      view.setUint16(20, this.viewportWidth, false);
      view.setUint16(22, this.viewportHeight, false);
      view.setUint16(24, avcCLen, false);
      view.setUint16(26, 0, false);

      if (avcCBytes && avcCLen > 0) {
        outBytes.set(avcCBytes, HEADER_BYTES);
      }
      chunk.copyTo(outBytes.subarray(HEADER_BYTES + avcCLen));

      try {
        streamWs.send(buffer);
      } catch (_) {
        this.needsKeyframe = true;
      }
    }

    stop(closeSocketIfIdle = true) {
      this.state = 'stopped';
      clearTimeout(this.settleTimer);
      this.settleTimer = null;
      clearTimeout(this.catchUpTimer);
      this.catchUpTimer = null;

      if (this.reader) {
        const r = this.reader;
        this.reader = null;
        r.cancel().catch(() => {});
      }
      if (this.encoder) {
        const enc = this.encoder;
        this.encoder = null;
        if (enc.state !== 'closed') {
          try {
            enc.close();
          } catch (_) {}
        }
      }
      if (this.lastVideoFrame) {
        try {
          this.lastVideoFrame.close();
        } catch (_) {}
        this.lastVideoFrame = null;
      }
      if (this.videoTrack) {
        try {
          this.videoTrack.stop();
        } catch (_) {}
        this.videoTrack = null;
      }
      this.mediaStream = null;

      if (closeSocketIfIdle && pipelines.size === 0 && streamWs) {
        try {
          streamWs.close();
        } catch (_) {}
        streamWs = null;
        streamWsAuthenticated = false;
      }
    }
  }

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (!msg || typeof msg.type !== 'string') return false;

    switch (msg.type) {
      case 'OFFSCREEN_CONFIGURE_ENDPOINT': {
        endpointConfig = {
          wsPort: msg.wsPort,
          token: msg.token,
          extensionInstanceId: msg.extensionInstanceId,
          browserBundleId: msg.browserBundleId,
          extensionVersion: msg.extensionVersion
        };
        if (pipelines.size > 0) {
          ensureStreamSocket();
        }
        sendResponse({ ok: true });
        return false;
      }

      case 'OFFSCREEN_HAS_ACTIVE_STREAM': {
        const existing = pipelines.get(msg.tabId >>> 0);
        sendResponse({ active: Boolean(existing && existing.state !== 'stopped') });
        return false;
      }

      case 'OFFSCREEN_START_TAB_STREAM': {
        (async () => {
          const tabId = msg.tabId >>> 0;
          const existing = pipelines.get(tabId);
          if (existing && existing.state !== 'stopped') {
            existing.updateViewport(msg.viewportWidth, msg.viewportHeight);
            sendResponse({ ok: true, reused: true });
            return;
          }
          const pipeline = new TabPipeline(tabId, msg.viewportWidth, msg.viewportHeight);
          pipelines.set(tabId, pipeline);
          try {
            await pipeline.startWithStreamId(msg.streamId);
            sendResponse({ ok: true, reused: false });
          } catch (err) {
            pipelines.delete(tabId);
            pipeline.stop(true);
            sendResponse({ ok: false, error: String(err && err.message ? err.message : err) });
          }
        })();
        return true;
      }

      case 'OFFSCREEN_CONFIRM_CROP': {
        const pipeline = pipelines.get(msg.tabId >>> 0);
        if (!pipeline) {
          sendResponse({ ok: false, error: 'No active capture pipeline for tab' });
          return false;
        }
        pipeline.updateViewport(msg.viewportWidth, msg.viewportHeight);
        pipeline.confirmCrop(Boolean(msg.skipSettleDelay));
        sendResponse({ ok: true });
        return false;
      }

      case 'OFFSCREEN_UPDATE_VIEWPORT': {
        const pipeline = pipelines.get(msg.tabId >>> 0);
        if (pipeline) {
          pipeline.updateViewport(msg.viewportWidth, msg.viewportHeight);
        }
        sendResponse({ ok: true });
        return false;
      }

      case 'OFFSCREEN_FORCE_KEYFRAME': {
        const pipeline = pipelines.get(msg.tabId >>> 0);
        if (pipeline) {
          pipeline.forceImmediateKeyframe();
        }
        sendResponse({ ok: true });
        return false;
      }

      case 'OFFSCREEN_STOP_TAB_STREAM': {
        const tabId = msg.tabId >>> 0;
        const pipeline = pipelines.get(tabId);
        pipelines.delete(tabId);
        if (pipeline) {
          pipeline.stop(true);
        }
        sendResponse({ ok: true });
        return false;
      }

      default:
        return false;
    }
  });
})();
