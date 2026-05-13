import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  switch(event) {
    const locale = event.target.value
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    // Use fetch so Turbo never intercepts the request, then force a full
    // page reload so <html lang> and <html dir> are updated by the server.
    fetch("/preferences/locale", {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json",
      },
      body: JSON.stringify({ locale }),
    })
      .catch(() => {})
      .finally(() => {
        window.location.reload()
      })
  }
}
