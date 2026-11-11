(() => {
  'use strict';

  if (typeof window.__peekPaneCropOverlayCleanup === 'function') {
    window.__peekPaneCropOverlayCleanup();
  }

  const MIN_SNAP_WIDTH = 64;
  const MIN_SNAP_HEIGHT = 48;
  const DRAG_THRESHOLD_PX = 5;
  const MIN_CROP_BOX_PX = 36;

  const host = document.createElement('div');
  host.id = '__peekpane-crop-host';
  Object.assign(host.style, {
    position: 'fixed',
    inset: '0',
    width: '100vw',
    height: '100vh',
    zIndex: '2147483647',
    cursor: 'crosshair',
    userSelect: 'none',
    webkitUserSelect: 'none',
    touchAction: 'none'
  });

  const shadow = host.attachShadow({ mode: 'closed' });
  const style = document.createElement('style');
  style.textContent = `
    :host {
      all: initial;
    }
    .backdrop {
      position: fixed;
      inset: 0;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    }
    .selection-box {
      position: fixed;
      pointer-events: none;
      border: 2px solid #0A84FF;
      border-radius: 6px;
      box-shadow: 0 0 0 9999px rgba(8, 12, 20, 0.45), 0 0 0 1px rgba(255, 255, 255, 0.32) inset;
      display: none;
    }
    .size-badge {
      position: absolute;
      left: 0;
      bottom: -26px;
      background: rgba(16, 20, 28, 0.9);
      color: #fff;
      font-size: 11px;
      font-weight: 600;
      padding: 3px 7px;
      border-radius: 5px;
      white-space: nowrap;
      border: 1px solid rgba(255, 255, 255, 0.16);
    }
    .top-pill {
      position: fixed;
      top: 16px;
      left: 50%;
      transform: translateX(-50%);
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 8px 14px;
      border-radius: 999px;
      background: rgba(18, 22, 30, 0.88);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      border: 1px solid rgba(255, 255, 255, 0.18);
      box-shadow: 0 10px 28px rgba(0, 0, 0, 0.35);
      color: rgba(255, 255, 255, 0.95);
      font-size: 12px;
      font-weight: 500;
      z-index: 2;
    }
    .pill-btn {
      appearance: none;
      border: 1px solid rgba(255, 255, 255, 0.22);
      background: #0A84FF;
      color: #fff;
      font-size: 11.5px;
      font-weight: 600;
      padding: 4px 10px;
      border-radius: 999px;
      cursor: pointer;
    }
    .pill-btn:hover {
      background: #2291FF;
    }
    .pill-cancel {
      background: rgba(255, 255, 255, 0.12);
    }
    .pill-cancel:hover {
      background: rgba(255, 255, 255, 0.2);
    }
  `;

  const backdrop = document.createElement('div');
  backdrop.className = 'backdrop';

  const selectionBox = document.createElement('div');
  selectionBox.className = 'selection-box';
  const sizeBadge = document.createElement('div');
  sizeBadge.className = 'size-badge';
  selectionBox.appendChild(sizeBadge);

  const topPill = document.createElement('div');
  topPill.className = 'top-pill';

  const promptSpan = document.createElement('span');
  promptSpan.textContent = 'Click highlighted element or drag custom box';

  const fullTabBtn = document.createElement('button');
  fullTabBtn.type = 'button';
  fullTabBtn.className = 'pill-btn';
  fullTabBtn.textContent = 'Float Full Tab';

  const cancelBtn = document.createElement('button');
  cancelBtn.type = 'button';
  cancelBtn.className = 'pill-btn pill-cancel';
  cancelBtn.textContent = 'Esc';

  topPill.append(promptSpan, fullTabBtn, cancelBtn);
  backdrop.append(selectionBox, topPill);
  shadow.append(style, backdrop);
  (document.documentElement || document.body).appendChild(host);

  let isDragging = false;
  let pointerDown = false;
  let startX = 0;
  let startY = 0;
  let hoveredRect = null;
  let isFinished = false;

  const PREFERRED_TAGS = new Set(['VIDEO', 'CANVAS', 'IFRAME', 'IMG', 'SVG', 'FIGURE', 'ARTICLE', 'SECTION', 'ASIDE', 'TABLE']);

  function clampRectToViewport(rect) {
    const vw = Math.max(1, window.innerWidth);
    const vh = Math.max(1, window.innerHeight);
    const left = Math.max(0, Math.min(vw - 1, rect.left));
    const top = Math.max(0, Math.min(vh - 1, rect.top));
    const right = Math.max(left + 1, Math.min(vw, rect.right));
    const bottom = Math.max(top + 1, Math.min(vh, rect.bottom));
    return { x: left, y: top, width: right - left, height: bottom - top };
  }

  function pickSnapRectAt(clientX, clientY) {
    host.style.pointerEvents = 'none';
    let el = null;
    try {
      el = document.elementFromPoint(clientX, clientY);
    } finally {
      host.style.pointerEvents = 'auto';
    }
    if (!el) return null;

    const vw = Math.max(1, window.innerWidth);
    const vh = Math.max(1, window.innerHeight);
    let fallbackCandidate = null;
    let current = el;

    while (current && current !== document.body && current !== document.documentElement) {
      const raw = current.getBoundingClientRect();
      const clamped = clampRectToViewport(raw);
      const areaRatio = (clamped.width * clamped.height) / (vw * vh);
      if (clamped.width >= MIN_SNAP_WIDTH && clamped.height >= MIN_SNAP_HEIGHT && areaRatio <= 0.94) {
        if (PREFERRED_TAGS.has(current.tagName)) {
          return clamped;
        }
        if (!fallbackCandidate) {
          fallbackCandidate = clamped;
        }
      }
      current = current.parentElement;
    }
    return fallbackCandidate;
  }

  function renderBox(rect, labelPrefix) {
    if (!rect) {
      selectionBox.style.display = 'none';
      return;
    }
    selectionBox.style.display = 'block';
    selectionBox.style.left = `${Math.round(rect.x)}px`;
    selectionBox.style.top = `${Math.round(rect.y)}px`;
    selectionBox.style.width = `${Math.round(rect.width)}px`;
    selectionBox.style.height = `${Math.round(rect.height)}px`;
    const prefix = labelPrefix ? `${labelPrefix} · ` : '';
    sizeBadge.textContent = `${prefix}${Math.round(rect.width)} × ${Math.round(rect.height)}`;
  }

  function toNormalizedCrop(rect) {
    const vw = Math.max(1, window.innerWidth);
    const vh = Math.max(1, window.innerHeight);
    const width = Math.max(0.042, Math.min(1, rect.width / vw));
    const height = Math.max(0.042, Math.min(1, rect.height / vh));
    const x = Math.max(0, Math.min(1 - width, rect.x / vw));
    const y = Math.max(0, Math.min(1 - height, rect.y / vh));
    return { x, y, width, height };
  }

  function removeOverlayListenersAndDOM() {
    window.removeEventListener('keydown', onKeyDown, true);
    backdrop.removeEventListener('pointerdown', onPointerDown);
    backdrop.removeEventListener('pointermove', onPointerMove);
    backdrop.removeEventListener('pointerup', onPointerUp);
    host.remove();
    delete window.__peekPaneCropOverlayCleanup;
  }

  function confirmWithNormalizedCrop(normalizedCrop) {
    if (isFinished) return;
    isFinished = true;
    removeOverlayListenersAndDOM();

    // Wait two rAF ticks after DOM removal so Blink/Viz paints a clean frame without the overlay.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        chrome.runtime.sendMessage({
          type: 'OVERLAY_CROP_CONFIRMED',
          cropRect: normalizedCrop,
          viewportWidth: Math.max(64, Math.round(window.innerWidth)),
          viewportHeight: Math.max(64, Math.round(window.innerHeight)),
          title: document.title || '',
          urlHost: window.location.hostname || ''
        });
      });
    });
  }

  function cancelSelection() {
    if (isFinished) return;
    isFinished = true;
    removeOverlayListenersAndDOM();
    chrome.runtime.sendMessage({ type: 'OVERLAY_CROP_CANCELLED' });
  }

  function onPointerDown(event) {
    if (event.button !== 0) return;
    if (topPill.contains(event.target)) return;
    pointerDown = true;
    isDragging = false;
    startX = event.clientX;
    startY = event.clientY;
    backdrop.setPointerCapture(event.pointerId);
  }

  function onPointerMove(event) {
    if (topPill.contains(event.target) && !pointerDown) {
      renderBox(null, '');
      hoveredRect = null;
      return;
    }

    if (pointerDown) {
      const dx = event.clientX - startX;
      const dy = event.clientY - startY;
      if (!isDragging && Math.hypot(dx, dy) >= DRAG_THRESHOLD_PX) {
        isDragging = true;
      }
      if (isDragging) {
        const left = Math.max(0, Math.min(startX, event.clientX));
        const top = Math.max(0, Math.min(startY, event.clientY));
        const right = Math.min(window.innerWidth, Math.max(startX, event.clientX));
        const bottom = Math.min(window.innerHeight, Math.max(startY, event.clientY));
        renderBox({ x: left, y: top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) }, 'Crop');
      }
      return;
    }

    hoveredRect = pickSnapRectAt(event.clientX, event.clientY);
    renderBox(hoveredRect, 'Snap');
  }

  function onPointerUp(event) {
    if (!pointerDown) return;
    pointerDown = false;
    try {
      backdrop.releasePointerCapture(event.pointerId);
    } catch (_) {
      // Ignore if pointer capture was already released.
    }

    if (isDragging) {
      const left = Math.max(0, Math.min(startX, event.clientX));
      const top = Math.max(0, Math.min(startY, event.clientY));
      const right = Math.min(window.innerWidth, Math.max(startX, event.clientX));
      const bottom = Math.min(window.innerHeight, Math.max(startY, event.clientY));
      const width = right - left;
      const height = bottom - top;
      if (width >= MIN_CROP_BOX_PX && height >= MIN_CROP_BOX_PX) {
        confirmWithNormalizedCrop(toNormalizedCrop({ x: left, y: top, width, height }));
      } else {
        isDragging = false;
        renderBox(null, '');
      }
      return;
    }

    const snap = hoveredRect || pickSnapRectAt(event.clientX, event.clientY);
    if (snap) {
      confirmWithNormalizedCrop(toNormalizedCrop(snap));
    }
  }

  function onKeyDown(event) {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      cancelSelection();
    }
  }

  fullTabBtn.addEventListener('click', (event) => {
    event.stopPropagation();
    confirmWithNormalizedCrop({ x: 0, y: 0, width: 1, height: 1 });
  });

  cancelBtn.addEventListener('click', (event) => {
    event.stopPropagation();
    cancelSelection();
  });

  backdrop.addEventListener('pointerdown', onPointerDown);
  backdrop.addEventListener('pointermove', onPointerMove);
  backdrop.addEventListener('pointerup', onPointerUp);
  window.addEventListener('keydown', onKeyDown, true);

  window.__peekPaneCropOverlayCleanup = cancelSelection;
})();
