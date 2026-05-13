import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["androidBanner", "iosBanner"]

  connect() {
    // Already installed as a PWA — nothing to show
    if (this.#isStandalone()) return;

    // Dismissed earlier in this session
    if (sessionStorage.getItem("pwa-banner-dismissed")) return;

    if (this.#isIOS()) {
      this.#show(this.hasIosBannerTarget ? this.iosBannerTarget : null);
    } else if (window.__pwaInstallPrompt) {
      this.#show(this.hasAndroidBannerTarget ? this.androidBannerTarget : null);
    } else {
      // Wait for the browser to fire beforeinstallprompt (Chrome/Edge/Android)
      document.addEventListener(
        "pwa:installable",
        () => this.#show(this.hasAndroidBannerTarget ? this.androidBannerTarget : null),
        { once: true }
      );
    }

    document.addEventListener("pwa:installed", () => this.#dismissAll(), { once: true });
  }

  async install() {
    if (!window.__pwaInstallPrompt) return;
    window.__pwaInstallPrompt.prompt();
    const { outcome } = await window.__pwaInstallPrompt.userChoice;
    if (outcome === "accepted") {
      window.__pwaInstallPrompt = null;
      this.#dismissAll();
    }
  }

  dismiss() {
    sessionStorage.setItem("pwa-banner-dismissed", "1");
    this.#dismissAll();
  }

  // ── Private ────────────────────────────────────────────────────────────────

  #isStandalone() {
    return (
      window.matchMedia("(display-mode: standalone)").matches ||
      window.navigator.standalone === true
    );
  }

  #isIOS() {
    return /iPhone|iPad|iPod/.test(navigator.userAgent) && !window.MSStream;
  }

  #show(el) {
    if (el) el.hidden = false;
  }

  #dismissAll() {
    if (this.hasAndroidBannerTarget) this.androidBannerTarget.hidden = true;
    if (this.hasIosBannerTarget)     this.iosBannerTarget.hidden     = true;
  }
}
