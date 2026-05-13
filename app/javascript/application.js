import "@hotwired/turbo-rails"
import "controllers"

// Turbo replaces <body> but never touches <html lang> or <html dir>.
// Read the server-set meta tags on every page load and apply them so that
// RTL/LTR layout and screen-reader language are always in sync.
function syncHtmlLocale() {
  const locale = document.querySelector('meta[name="app-locale"]')?.content
  const dir    = document.querySelector('meta[name="app-dir"]')?.content
  if (locale) document.documentElement.lang = locale
  if (dir)    document.documentElement.dir  = dir
}

document.addEventListener("turbo:load", syncHtmlLocale)
document.addEventListener("turbo:render", syncHtmlLocale)

// Capture Android Chrome's install prompt before the browser shows its own UI.
// The pwa-install Stimulus controller reads window.__pwaInstallPrompt to trigger it.
window.addEventListener("beforeinstallprompt", (e) => {
  e.preventDefault();
  window.__pwaInstallPrompt = e;
  document.dispatchEvent(new CustomEvent("pwa:installable"));
});

window.addEventListener("appinstalled", () => {
  window.__pwaInstallPrompt = null;
  document.dispatchEvent(new CustomEvent("pwa:installed"));
});

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker
      .register("/service-worker.js", { scope: "/" })
      .catch((err) => console.error("[SW] Registration failed:", err));
  });
}
