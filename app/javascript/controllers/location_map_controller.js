import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]

  static values = {
    branchLat:    { type: Number, default: 0 },
    branchLng:    { type: Number, default: 0 },
    branchRadius: { type: Number, default: 100 },
    checkInLat:   { type: Number, default: 0 },
    checkInLng:   { type: Number, default: 0 },
    checkOutLat:  { type: Number, default: 0 },
    checkOutLng:  { type: Number, default: 0 },
    hasBranch:    { type: Boolean, default: false },
    hasCheckIn:   { type: Boolean, default: false },
    hasCheckOut:  { type: Boolean, default: false },
  }

  async connect() {
    const L = await import("leaflet")
    if (!this.hasContainerTarget) return

    this.#fixDefaultIcons(L.Icon)

    // Collect all points to fit the map bounds
    const points = []

    if (this.hasBranchValue) {
      points.push([this.branchLatValue, this.branchLngValue])
    }
    if (this.hasCheckInValue) {
      points.push([this.checkInLatValue, this.checkInLngValue])
    }
    if (this.hasCheckOutValue) {
      points.push([this.checkOutLatValue, this.checkOutLngValue])
    }

    if (!points.length) return

    // Center on the first available point
    this.map = L.map(this.containerTarget, { zoomControl: true }).setView(points[0], 15)

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '© <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>',
      maxZoom: 19,
    }).addTo(this.map)

    // Branch marker + radius circle
    if (this.hasBranchValue) {
      const branchIcon = L.divIcon({
        className: "",
        html: '<div class="loc-marker loc-marker--branch">B</div>',
        iconSize: [28, 28],
        iconAnchor: [14, 14],
      })
      L.marker([this.branchLatValue, this.branchLngValue], { icon: branchIcon })
        .addTo(this.map)
        .bindPopup("Branch location")

      L.circle([this.branchLatValue, this.branchLngValue], {
        radius:      this.branchRadiusValue,
        color:       "#94a3b8",
        fillColor:   "#94a3b8",
        fillOpacity: 0.12,
        weight:      1.5,
      }).addTo(this.map)
    }

    // Check-in marker
    if (this.hasCheckInValue) {
      const dist = this.hasBranchValue
        ? this.#haversine(this.branchLatValue, this.branchLngValue, this.checkInLatValue, this.checkInLngValue)
        : null
      const checkInIcon = L.divIcon({
        className: "",
        html: '<div class="loc-marker loc-marker--checkin"></div>',
        iconSize: [14, 14],
        iconAnchor: [7, 7],
      })
      L.marker([this.checkInLatValue, this.checkInLngValue], { icon: checkInIcon })
        .addTo(this.map)
        .bindPopup(`Check-in${dist !== null ? ` &mdash; ${dist}m from branch` : ""}`)
        .openPopup()
    }

    // Check-out marker
    if (this.hasCheckOutValue) {
      const dist = this.hasBranchValue
        ? this.#haversine(this.branchLatValue, this.branchLngValue, this.checkOutLatValue, this.checkOutLngValue)
        : null
      const checkOutIcon = L.divIcon({
        className: "",
        html: '<div class="loc-marker loc-marker--checkout"></div>',
        iconSize: [14, 14],
        iconAnchor: [7, 7],
      })
      L.marker([this.checkOutLatValue, this.checkOutLngValue], { icon: checkOutIcon })
        .addTo(this.map)
        .bindPopup(`Check-out${dist !== null ? ` &mdash; ${dist}m from branch` : ""}`)
    }

    // Fit all markers in view
    if (points.length > 1) {
      this.map.fitBounds(points, { padding: [40, 40] })
    }
  }

  disconnect() {
    this.map?.remove()
    this.map = null
  }

  // ── Private ──────────────────────────────────────────────────────────────

  #haversine(lat1, lng1, lat2, lng2) {
    const R = 6_371_000
    const toRad = (deg) => (deg * Math.PI) / 180
    const dLat = toRad(lat2 - lat1)
    const dLng = toRad(lng2 - lng1)
    const a =
      Math.sin(dLat / 2) ** 2 +
      Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2
    return Math.round(R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)))
  }

  #fixDefaultIcons(Icon) {
    if (!Icon?.Default) return
    delete Icon.Default.prototype._getIconUrl
    Icon.Default.mergeOptions({
      iconUrl:       "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png",
      iconRetinaUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png",
      shadowUrl:     "https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png",
    })
  }
}
