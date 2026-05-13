import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "lat", "lng", "radius", "search", "searchStatus"]

  // Default map center when no coordinates are saved (Riyadh)
  static values = {
    defaultLat: { type: Number, default: 24.7136 },
    defaultLng: { type: Number, default: 46.6753 },
  }

  connect() {
    this.initMap()
    this.handleShown = () => requestAnimationFrame(() => this.map?.invalidateSize())
    window.addEventListener("geo-fields:shown", this.handleShown)
  }

  disconnect() {
    this.map?.remove()
    this.map = null
    window.removeEventListener("geo-fields:shown", this.handleShown)
    clearTimeout(this.coordsTimer)
  }

  async initMap() {
    // Leaflet 1.9.x ESM has no default export — import named exports directly
    const L = await import("leaflet")
    if (!this.hasContainerTarget) return   // guard: disconnected during async load

    this.L = L  // { map, tileLayer, marker, circle, Icon, … }
    this.#fixDefaultIcons(L.Icon)

    const savedLat = this.#parseCoord(this.hasLatTarget && this.latTarget.value)
    const savedLng = this.#parseCoord(this.hasLngTarget && this.lngTarget.value)
    const hasCoords = savedLat !== null && savedLng !== null

    const centerLat = hasCoords ? savedLat : this.defaultLatValue
    const centerLng = hasCoords ? savedLng : this.defaultLngValue

    this.map = L.map(this.containerTarget).setView([centerLat, centerLng], hasCoords ? 15 : 12)

    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: '© <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>',
      maxZoom: 19,
    }).addTo(this.map)

    if (hasCoords) this.#placeMarker(savedLat, savedLng)

    this.map.on("click", ({ latlng }) => {
      this.#placeMarker(latlng.lat, latlng.lng)
      this.#syncInputs(latlng.lat, latlng.lng)
    })
  }

  // Triggered by lat/lng input events (debounced 500ms)
  onCoordsInput() {
    clearTimeout(this.coordsTimer)
    this.coordsTimer = setTimeout(() => {
      if (!this.map) return
      const lat = this.#parseCoord(this.latTarget.value)
      const lng = this.#parseCoord(this.lngTarget.value)
      if (lat !== null && lng !== null) {
        this.#placeMarker(lat, lng)
        this.map.panTo([lat, lng])
      }
    }, 500)
  }

  // Triggered by radius input events
  onRadiusChange() {
    this.mapCircle?.setRadius(this.#currentRadius())
  }

  // Address / area / city search via Nominatim
  async onSearch() {
    if (!this.hasSearchTarget) return
    const query = this.searchTarget.value.trim()
    if (!query) return

    this.#setStatus("Searching…")

    let results
    try {
      const url = `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(query)}&format=json&limit=1`
      const res = await fetch(url, { headers: { "Accept-Language": "en" } })
      results = await res.json()
    } catch {
      this.#setStatus("Search failed. Please check your connection.", true)
      return
    }

    if (!results.length) {
      this.#setStatus("No results found. Try a different search term.", true)
      return
    }

    const { lat, lon, display_name } = results[0]
    const parsedLat = parseFloat(lat)
    const parsedLng = parseFloat(lon)

    if (!this.map) return
    this.#placeMarker(parsedLat, parsedLng)
    this.#syncInputs(parsedLat, parsedLng)
    this.map.setView([parsedLat, parsedLng], 16)
    this.#setStatus(`Found: ${display_name}`)
  }

  // Use browser geolocation
  onUseLocation() {
    if (!navigator.geolocation) {
      this.#setStatus("Geolocation is not supported by your browser.", true)
      return
    }

    this.#setStatus("Detecting your location…")

    navigator.geolocation.getCurrentPosition(
      ({ coords }) => {
        const { latitude, longitude } = coords
        if (!this.map) return
        this.#placeMarker(latitude, longitude)
        this.#syncInputs(latitude, longitude)
        this.map.setView([latitude, longitude], 16)
        this.#setStatus("Location set to your current position.")
      },
      (err) => {
        const msg = err.code === err.PERMISSION_DENIED
          ? "Location access denied. Please allow location in your browser settings."
          : "Unable to detect your location. Try again."
        this.#setStatus(msg, true)
      },
      { timeout: 10000 }
    )
  }

  // ── Private ──────────────────────────────────────────────────────────────

  #setStatus(message, isError = false) {
    if (!this.hasSearchStatusTarget) return
    const el = this.searchStatusTarget
    el.textContent = message
    el.hidden = false
    el.classList.toggle("map-search-status--error", isError)
  }

  #placeMarker(lat, lng) {
    const radius = this.#currentRadius()

    if (this.mapMarker) {
      this.mapMarker.setLatLng([lat, lng])
      this.mapCircle.setLatLng([lat, lng])
      this.mapCircle.setRadius(radius)
    } else {
      this.mapMarker = this.L.marker([lat, lng], { draggable: true }).addTo(this.map)
      this.mapCircle = this.L.circle([lat, lng], {
        radius,
        color: "#54C6F9",
        fillColor: "#54C6F9",
        fillOpacity: 0.15,
        weight: 2,
      }).addTo(this.map)

      this.mapMarker.on("drag", ({ latlng }) => {
        this.mapCircle.setLatLng([latlng.lat, latlng.lng])
        this.#syncInputs(latlng.lat, latlng.lng)
      })
    }
  }

  #syncInputs(lat, lng) {
    if (this.hasLatTarget) this.latTarget.value = lat.toFixed(7)
    if (this.hasLngTarget) this.lngTarget.value = lng.toFixed(7)
  }

  #currentRadius() {
    const v = this.hasRadiusTarget && parseInt(this.radiusTarget.value)
    return v > 0 ? v : 100
  }

  #parseCoord(value) {
    if (!value && value !== 0) return null
    const n = parseFloat(value)
    return isNaN(n) ? null : n
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
