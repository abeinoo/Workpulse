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

// Auto-populate data-label on <td> cells in card tables by reading <th> text.
// Runs on every page load so Turbo navigation stays in sync.
function labelCardTables() {
  document.querySelectorAll(".table-wrap--cards, .table-wrap--form-cards").forEach(wrap => {
    const table = wrap.querySelector("table");
    if (!table) return;
    const headers = [...table.querySelectorAll("thead th")].map(th => th.textContent.trim());
    table.querySelectorAll("tbody tr").forEach(row => {
      [...row.querySelectorAll("td")].forEach((td, i) => {
        const label = headers[i];
        if (label) {
          td.setAttribute("data-label", label);
        } else {
          td.removeAttribute("data-label");
        }
      });
    });
  });
}

document.addEventListener("turbo:load", labelCardTables);
document.addEventListener("DOMContentLoaded", labelCardTables);

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
