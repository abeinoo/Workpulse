import { Controller } from "@hotwired/stimulus"

// Interactive 1–5 star rating bound to a hidden input.
//
// Usage:
//   <div data-controller="star-rating" data-star-rating-value-value="3">
//     <input type="hidden" data-star-rating-target="input" name="...[score]">
//     <button type="button" data-star-rating-target="star"
//             data-value="1" data-action="click->star-rating#select
//             mouseenter->star-rating#preview mouseleave->star-rating#reset">★</button>
//     ... (five buttons)
//   </div>
export default class extends Controller {
  static targets = ["star", "input"]
  static values  = { value: { type: Number, default: 0 } }

  connect() {
    this.#paint(this.valueValue)
  }

  select(event) {
    const value = Number(event.currentTarget.dataset.value)
    this.valueValue = value
    if (this.hasInputTarget) this.inputTarget.value = value
    this.#paint(value)
  }

  preview(event) {
    this.#paint(Number(event.currentTarget.dataset.value))
  }

  reset() {
    this.#paint(this.valueValue)
  }

  #paint(upTo) {
    this.starTargets.forEach((star) => {
      const on = Number(star.dataset.value) <= upTo
      star.classList.toggle("star--on", on)
      star.classList.toggle("star--off", !on)
      star.setAttribute("aria-pressed", on ? "true" : "false")
    })
  }
}
