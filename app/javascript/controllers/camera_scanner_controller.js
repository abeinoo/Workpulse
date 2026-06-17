import { Controller } from "@hotwired/stimulus"
import { BrowserMultiFormatReader } from "@zxing/browser"

// ─────────────────────────────────────────────────────────────────────────────
// Camera barcode scanner — Stimulus controller
//
// Modes (data-camera-scanner-mode-value):
//   "fill"   (default) – after a scan, writes the code into fillTarget and
//                        dispatches a synthetic Enter so a sibling
//                        barcode-scanner controller processes it normally.
//   "lookup" – after a scan, calls the barcode lookup API; on success
//              navigates to the product page; on failure shows a
//              "not found / create product" prompt.
//
// Multi-camera support
//   On first open the controller:
//     1. Does a permission probe (one getUserMedia call).
//     2. Enumerates video devices — labels are populated after step 1 on
//        Android/Chrome.  iOS Safari always returns empty labels (privacy),
//        so camera switching is only shown when labels are available.
//     3. Picks the best rear camera using a label-scoring heuristic.
//     4. Respects a previously saved deviceId from localStorage.
//     5. Shows a "switch camera" button when more than one labelled camera
//        is found.
//
// Cleanup guarantees
//   controls.stop() (returned by decodeFromConstraints) calls ZXing's own
//   disposeMediaStream() which stops every track and removes srcObject.
//   We never hold a separate stream reference, so there is no double-stream
//   or orphaned track problem.
// ─────────────────────────────────────────────────────────────────────────────

const STORAGE_KEY = "workpulse_scanner_camera_id"

export default class extends Controller {
  static targets = ["fill"]
  static values  = {
    mode:           { type: String, default: "fill" },
    lookupUrl:      { type: String, default: "" },
    productBaseUrl: { type: String, default: "" },
    newProductUrl:  { type: String, default: "" }
  }

  connect() {
    this._cameras     = []   // [{ deviceId, label, isFront }]
    this._cameraIndex = 0
    this._reader      = null
    this._controls    = null
    this._modal       = null
    this._scanning    = false  // guard against re-entrant scan callbacks
  }

  disconnect() {
    this.#stopCamera()
    this._modal?.remove()
    this._modal = null
  }

  open() {
    if (this._modal) return   // already open
    this._scanning = true
    this.#buildModal()
    document.body.appendChild(this._modal)
    document.body.style.overflow = "hidden"
    this.#initCameras()
  }

  close() {
    this._scanning = false
    this.#stopCamera()
    this._modal?.remove()
    this._modal = null
    document.body.style.overflow = ""
  }

  // ─── Camera initialisation ────────────────────────────────────────────────

  async #initCameras() {
    // Guard: non-HTTPS contexts (dev, some PWA misconfiguration) lack getUserMedia
    if (!navigator.mediaDevices?.getUserMedia) {
      this.#setStatus(this.#t("noCamera"))
      return
    }

    this.#setStatus(this.#t("starting"))

    // ① Permission probe — without a prior getUserMedia call, enumerateDevices
    //   returns devices with empty labels on all platforms.  We stop the probe
    //   stream immediately; its sole purpose is to trigger the permission dialog
    //   and populate labels on Android/Chrome.
    try {
      const probe = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } })
      probe.getTracks().forEach(t => t.stop())
    } catch (err) {
      this.#handleCameraError(err)
      return
    }

    // ② Enumerate video input devices
    let devices = []
    try {
      devices = (await navigator.mediaDevices.enumerateDevices())
        .filter(d => d.kind === "videoinput")
    } catch {
      // enumerateDevices not supported (very old browser); treat as single camera
    }

    if (!devices.length) {
      // Fallback: create a synthetic entry that uses facingMode instead of deviceId
      devices = [{ deviceId: "", label: "" }]
    }

    // iOS Safari always returns empty labels for privacy; Android/Chrome
    // populates them after the permission probe above.
    const hasLabels = devices.some(d => d.label.length > 0)

    this._cameras = devices.map(d => ({
      deviceId: d.deviceId,
      label:    d.label,
      isFront:  hasLabels && /front|selfie|user|facing front/i.test(d.label)
    }))

    // ③ Pick the best starting camera
    this._cameraIndex = this.#resolveCameraIndex(hasLabels)

    // ④ Show switch button only when we have multiple labelled cameras.
    //   Without labels we cannot tell front from rear, so cycling blindly
    //   would be confusing on phones where index 0 is the front camera.
    if (hasLabels && this._cameras.length > 1) {
      this.#revealSwitchButton()
    }

    // ⑤ Start scanning
    await this.#startCameraAtIndex(this._cameraIndex)
  }

  // Returns the index of the camera to open first.
  #resolveCameraIndex(hasLabels) {
    if (this._cameras.length === 1) return 0

    // Honour the user's last-used camera if it still exists in the device list
    const saved = this.#getSavedCameraIndex()
    if (saved !== null) return saved

    // No saved preference — pick by barcode-suitability score
    if (!hasLabels) return 0   // can't score; trust OS default (index 0)

    const scored = this._cameras.map((cam, i) => ({ i, s: this.#cameraScore(cam) }))
    scored.sort((a, b) => b.s - a.s)
    return scored[0].i
  }

  // Higher score = better camera for barcode scanning.
  //
  // Rear / wide-angle cameras score highest.  Ultra-wide lenses introduce
  // barrel distortion and lose resolution per degree of FOV.  Telephoto lenses
  // require the user to stand far back.  Front cameras are never chosen
  // automatically.
  //
  // Label patterns tested against:
  //   iPhone   – "Back Camera", "Back Ultra Wide Camera", "Back Telephoto Camera"
  //   Pixel    – "0" (main), "1" (front), "2" (ultra-wide)
  //   Samsung  – "back", "front"
  //   Poco/Xiaomi – "facing back", numeric IDs, "camera2 0,facing back"
  //   Generic  – "environment", "user"
  #cameraScore({ label, isFront }) {
    if (isFront) return -10

    const l = label.toLowerCase()

    // Ultra-wide and telephoto: not ideal for barcode scanning
    if (/ultra.?wide|ultrawide|0\.5\s*mm|0\.6\s*mm/.test(l)) return 1
    if (/tele|zoom|periscope|5x|10x|portrait/.test(l))        return 1

    // Main / standard wide-angle rear camera: best choice
    if (/back camera$|^back$|rear|main|\benvironment\b|back wide|\b0°/.test(l)) return 5

    // Generic unlabelled or positively identified rear camera
    return 3
  }

  #getSavedCameraIndex() {
    try {
      const id = localStorage.getItem(STORAGE_KEY)
      if (!id) return null
      const idx = this._cameras.findIndex(c => c.deviceId === id)
      return idx === -1 ? null : idx
    } catch {
      return null
    }
  }

  #saveCamera(deviceId) {
    try { if (deviceId) localStorage.setItem(STORAGE_KEY, deviceId) } catch {}
  }

  // ─── Camera start / switch / stop ─────────────────────────────────────────

  async #startCameraAtIndex(index) {
    if (!this._modal) return

    // Stop any running decode loop + release the stream it owns.
    // controls.stop() (from decodeFromConstraints) calls ZXing's internal
    // disposeMediaStream() which stops every MediaStreamTrack and clears
    // srcObject — no separate stream cleanup is needed.
    try { this._controls?.stop() } catch {}
    this._controls = null
    this._reader   = null

    const cam   = this._cameras[index]
    const video = this._modal.querySelector(".cs-video")

    this.#setStatus(this.#t("starting"))

    try {
      // Build constraints — prefer explicit deviceId when available so the OS
      // opens exactly the camera the user (or our heuristic) selected.
      // Fall back to facingMode when deviceId is empty (iOS, single-camera fallback).
      const videoConstraints = cam.deviceId
        ? { deviceId: { exact: cam.deviceId }, width: { ideal: 1280 }, height: { ideal: 720 } }
        : { facingMode: "environment",          width: { ideal: 1280 }, height: { ideal: 720 } }

      this._reader   = new BrowserMultiFormatReader()
      this._controls = await this._reader.decodeFromConstraints(
        { video: videoConstraints },
        video,
        (result, error) => {
          if (!this._scanning) return   // scan already handled; ignore late callbacks
          if (result) this.#onScan(result.getText())
          if (error && error.constructor.name !== "NotFoundException") {
            console.warn("[CameraScanner]", error)
          }
        }
      )

      this.#clearStatus()
      this.#saveCamera(cam.deviceId)

    } catch (err) {
      this.#handleCameraError(err)
    }
  }

  async #switchCamera() {
    if (!this._cameras.length) return

    const btn = this._modal?.querySelector(".cs-switch-btn")
    if (btn) btn.disabled = true

    this._cameraIndex = (this._cameraIndex + 1) % this._cameras.length
    await this.#startCameraAtIndex(this._cameraIndex)

    if (btn) btn.disabled = false
  }

  // Stop decoding and release the camera.  ZXing's controls.stop() disposes
  // the MediaStream it opened via decodeFromConstraints, so we do not need
  // to track this._stream separately.
  #stopCamera() {
    try { this._controls?.stop() } catch {}
    this._controls = null
    this._reader   = null
  }

  // ─── Scan result ──────────────────────────────────────────────────────────

  #onScan(code) {
    this._scanning = false   // prevent any further callbacks from firing
    this.#stopCamera()
    this.#playBeep()
    this.#showSuccess(code)

    setTimeout(() => {
      this.close()
      if (this.modeValue === "lookup") {
        this.#lookup(code)
      } else {
        this.#fillInput(code)
      }
    }, 500)
  }

  #fillInput(code) {
    if (!this.hasFillTarget) return
    this.fillTarget.value = code
    this.fillTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.fillTarget.dispatchEvent(
      new KeyboardEvent("keydown", {
        key: "Enter", code: "Enter", keyCode: 13, bubbles: true, cancelable: true
      })
    )
    this.fillTarget.focus()
  }

  async #lookup(code) {
    if (!this.lookupUrlValue) return
    try {
      const res  = await fetch(`${this.lookupUrlValue}?code=${encodeURIComponent(code)}`,
                               { headers: { Accept: "application/json" } })
      const data = await res.json()
      if (res.ok && data.id) {
        window.location.href = `${this.productBaseUrlValue.replace(/\/$/, "")}/${data.id}`
      } else {
        this.#showNotFound(code)
      }
    } catch {
      this.#showNotFound(code)
    }
  }

  // ─── Modal DOM ────────────────────────────────────────────────────────────

  #buildModal() {
    const modal = document.createElement("div")
    modal.className = "cs-modal"
    modal.setAttribute("role", "dialog")
    modal.setAttribute("aria-modal", "true")
    modal.setAttribute("aria-label", this.#t("title"))
    modal.innerHTML = `
      <div class="cs-backdrop"></div>
      <div class="cs-dialog">
        <div class="cs-header">
          <span class="cs-title">${this.#t("title")}</span>
          <div class="cs-header-actions">
            <button type="button" class="cs-switch-btn" aria-label="${this.#t("switchCamera")}" hidden>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <path d="M20 7h-3.17L15 5H9L7.17 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2z"/>
                <polyline points="15.5 10.5 18 13 15.5 15.5"/>
                <polyline points="8.5 10.5 6 13 8.5 15.5"/>
              </svg>
            </button>
            <button type="button" class="cs-close" aria-label="${this.#t("close")}">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" aria-hidden="true">
                <line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>
              </svg>
            </button>
          </div>
        </div>
        <div class="cs-viewfinder">
          <video class="cs-video" playsinline autoplay muted></video>
          <div class="cs-overlay">
            <div class="cs-frame">
              <div class="cs-corner cs-corner--tl"></div>
              <div class="cs-corner cs-corner--tr"></div>
              <div class="cs-corner cs-corner--bl"></div>
              <div class="cs-corner cs-corner--br"></div>
              <div class="cs-scan-line"></div>
            </div>
          </div>
          <div class="cs-success" hidden>
            <div class="cs-success__icon">
              <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                <polyline points="20 6 9 17 4 12"/>
              </svg>
            </div>
            <div class="cs-success__code"></div>
          </div>
          <p class="cs-status" hidden></p>
        </div>
        <p class="cs-hint">${this.#t("hint")}</p>
      </div>
    `

    modal.querySelector(".cs-close").addEventListener("click",     () => this.close())
    modal.querySelector(".cs-backdrop").addEventListener("click",   () => this.close())
    modal.querySelector(".cs-switch-btn").addEventListener("click", () => this.#switchCamera())
    modal.addEventListener("keydown", e => {
      if (e.key === "Escape") { e.stopPropagation(); this.close() }
    })

    this._modal = modal
  }

  #revealSwitchButton() {
    const btn = this._modal?.querySelector(".cs-switch-btn")
    if (btn) btn.hidden = false
  }

  // ─── UI helpers ───────────────────────────────────────────────────────────

  #setStatus(text) {
    const el = this._modal?.querySelector(".cs-status")
    if (!el) return
    el.textContent = text
    el.hidden = false
  }

  #clearStatus() {
    const el = this._modal?.querySelector(".cs-status")
    if (el) el.hidden = true
  }

  #handleCameraError(err) {
    if (err.name === "NotAllowedError" || err.name === "PermissionDeniedError") {
      this.#setStatus(this.#t("permissionDenied"))
    } else if (err.name === "NotFoundError") {
      this.#setStatus(this.#t("noCamera"))
    } else {
      this.#setStatus(this.#t("startError"))
      console.error("[CameraScanner]", err)
    }
  }

  #showSuccess(code) {
    const el = this._modal?.querySelector(".cs-success")
    if (!el) return
    el.querySelector(".cs-success__code").textContent = code
    el.hidden = false
  }

  #showNotFound(code) {
    const dialog = document.createElement("div")
    dialog.className = "cs-not-found-dialog"
    dialog.innerHTML = `
      <div class="cs-not-found-backdrop"></div>
      <div class="cs-not-found-box">
        <p class="cs-not-found-msg">${this.#t("notFound", { code: this.#esc(code) })}</p>
        <div class="cs-not-found-actions">
          <a class="btn btn-primary btn-sm"
             href="${this.#esc(this.newProductUrlValue)}?barcode=${encodeURIComponent(code)}">
            ${this.#t("createProduct")}
          </a>
          <button class="btn btn-ghost btn-sm cs-not-found-dismiss">
            ${this.#t("dismiss")}
          </button>
        </div>
      </div>
    `
    dialog.querySelector(".cs-not-found-dismiss").addEventListener("click",   () => dialog.remove())
    dialog.querySelector(".cs-not-found-backdrop").addEventListener("click",  () => dialog.remove())
    document.body.appendChild(dialog)
  }

  #playBeep() {
    try {
      const ctx  = new (window.AudioContext || window.webkitAudioContext)()
      const osc  = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.frequency.value = 1480
      osc.type = "sine"
      gain.gain.setValueAtTime(0.25, ctx.currentTime)
      gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.12)
      osc.start(ctx.currentTime)
      osc.stop(ctx.currentTime + 0.12)
      osc.onended = () => ctx.close()
    } catch { /* audio not available in this context */ }
  }

  #esc(str) {
    const el = document.createElement("span")
    el.textContent = str || ""
    return el.innerHTML
  }

  // Reads locale strings from data attributes on the controller element so
  // the server can inject the correct language.  English strings are the
  // fallback in case an attribute is missing.
  #t(key, vars = {}) {
    const ds = this.element.dataset
    const map = {
      title:           ds.cameraScannerI18nTitle           || "Scan Barcode",
      close:           ds.cameraScannerI18nClose           || "Close",
      hint:            ds.cameraScannerI18nHint            || "Point your camera at a barcode",
      starting:        ds.cameraScannerI18nStarting        || "Starting camera…",
      switchCamera:    ds.cameraScannerI18nSwitchCamera    || "Switch camera",
      permissionDenied:ds.cameraScannerI18nPermissionDenied|| "Camera access denied. Tap the camera icon in your browser address bar to allow access.",
      noCamera:        ds.cameraScannerI18nNoCamera        || "No camera found on this device.",
      startError:      ds.cameraScannerI18nStartError      || "Unable to start camera.",
      notFound:        ds.cameraScannerI18nNotFound        || 'No product found for barcode "%{code}".',
      createProduct:   ds.cameraScannerI18nCreateProduct   || "Create new product",
      dismiss:         ds.cameraScannerI18nDismiss         || "Dismiss"
    }
    let text = map[key] || key
    Object.entries(vars).forEach(([k, v]) => { text = text.replace(`%{${k}}`, v) })
    return text
  }
}
