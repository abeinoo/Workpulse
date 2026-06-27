import { Controller } from "@hotwired/stimulus"

// Handles expand/collapse for a single audit timeline event row.
// Usage: data-controller="timeline-event" on the event container.
// Add data-timeline-event-target="detail" to the collapsible panel
// and data-timeline-event-target="chevron" to the toggle icon.
export default class extends Controller {
  static targets = ["detail", "chevron"]

  toggle(event) {
    event.stopPropagation()
    const isExpanded = !this.detailTarget.hidden
    this.detailTarget.hidden = isExpanded
    this.chevronTarget.style.transform = isExpanded ? "" : "rotate(180deg)"
  }
}
