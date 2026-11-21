import { Controller } from "@hotwired/stimulus"

// Product image gallery (Product New / Edit, _gallery.html.erb).
//
// The list of thumbnails IS the gallery, in order: the first item is the
// primary image (shown large). Each item carries data-entry —
//   "image:<id>"           an image already saved on the product
//   "upload:<signed id>"   a photo staged on the server (not attached yet)
//   ""                     still uploading, or failed (never submitted)
// After every change the hidden product[gallery][] fields (form="product-form")
// are rewritten from the list, so Save applies exactly what is shown
// (Inventory::ProductGalleryUpdater). Nothing changes on the product before Save.
//
// Uploads: each chosen / dropped photo is checked here (type, size, count),
// previewed at once from the local file, and uploaded with progress to the
// staging endpoint. Save stays disabled while any upload is running.
// Reorder: drag a thumbnail, or use its earlier / later / primary buttons
// (keyboard). Remove asks for confirmation.
export default class extends Controller {
  static targets = ["list", "item", "inputs", "main", "dropzone", "fileInput",
                    "itemTemplate", "emptyTemplate", "errors", "count"]
  static values  = { uploadUrl: String, maxFiles: Number, maxBytes: Number, types: Array, messages: Object }

  connect() {
    this.uploads = 0
    this.objectUrls = []
    this.refresh()
  }

  disconnect() {
    this.objectUrls.forEach((url) => URL.revokeObjectURL(url))
  }

  // ── Adding photos ────────────────────────────────────────────────────────
  pickFiles(event) {
    this.addFiles(Array.from(event.target.files || []))
    event.target.value = ""
  }

  dragOverZone(event) {
    if (!this.#hasFiles(event)) return
    event.preventDefault()
    this.element.classList.add("is-dragover")
  }

  dragLeaveZone(event) {
    if (event.relatedTarget && this.element.contains(event.relatedTarget)) return
    this.element.classList.remove("is-dragover")
  }

  dropFiles(event) {
    if (!this.#hasFiles(event)) return
    event.preventDefault()
    this.element.classList.remove("is-dragover")
    this.addFiles(Array.from(event.dataTransfer.files || []))
  }

  addFiles(files) {
    const errors = []
    files.forEach((file) => {
      if (this.itemTargets.length >= this.maxFilesValue) { errors.push(this.messagesValue.too_many); return }
      if (!this.typesValue.includes(file.type)) { errors.push(`${file.name}: ${this.messagesValue.invalid_type}`); return }
      if (file.size > this.maxBytesValue) { errors.push(`${file.name}: ${this.messagesValue.too_large}`); return }
      this.#upload(file, this.#newItem(file))
    })
    this.#showErrors([ ...new Set(errors) ])
    this.refresh()
  }

  // ── Reordering ───────────────────────────────────────────────────────────
  dragStart(event) {
    this.dragged = event.currentTarget
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", "gallery-item")
    this.dragged.classList.add("is-dragging")
  }

  dragOver(event) {
    if (!this.dragged || event.currentTarget === this.dragged) return
    event.preventDefault()
    const target = event.currentTarget
    const rect = target.getBoundingClientRect()
    const rtl = getComputedStyle(this.listTarget).direction === "rtl"
    const after = rtl ? event.clientX < rect.left + rect.width / 2 : event.clientX > rect.left + rect.width / 2
    target.parentNode.insertBefore(this.dragged, after ? target.nextSibling : target)
  }

  dropItem(event) {
    if (this.dragged) event.preventDefault()
  }

  dragEnd() {
    this.dragged?.classList.remove("is-dragging")
    this.dragged = null
    this.refresh()
  }

  makePrimary(event) {
    const item = this.#itemOf(event)
    this.listTarget.prepend(item)
    this.refresh()
    item.querySelector("[data-role='make-primary']")?.blur()
  }

  moveEarlier(event) {
    const item = this.#itemOf(event)
    if (item.previousElementSibling) item.parentNode.insertBefore(item, item.previousElementSibling)
    this.refresh()
    event.currentTarget.focus()
  }

  moveLater(event) {
    const item = this.#itemOf(event)
    if (item.nextElementSibling) item.parentNode.insertBefore(item.nextElementSibling, item)
    this.refresh()
    event.currentTarget.focus()
  }

  remove(event) {
    const item = this.#itemOf(event)
    if (!window.confirm(this.messagesValue.remove_confirm)) return
    item.xhr?.abort()
    item.remove()
    this.refresh()
  }

  // ── State → DOM ──────────────────────────────────────────────────────────
  refresh() {
    const items = this.itemTargets
    items.forEach((item, index) => item.classList.toggle("is-primary", index === 0))
    this.#renderMain(items[0])
    this.inputsTarget.innerHTML = ""
    items.forEach((item) => {
      if (!item.dataset.entry) return
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "product[gallery][]"
      input.value = item.dataset.entry
      input.setAttribute("form", "product-form")
      this.inputsTarget.appendChild(input)
    })
    if (this.hasCountTarget) {
      this.countTarget.textContent = this.countTarget.textContent.replace(/\d+/, String(items.length))
    }
    this.dropzoneTarget.hidden = items.length >= this.maxFilesValue
    this.#toggleSave()
  }

  #renderMain(first) {
    const main = this.mainTarget
    main.innerHTML = ""
    if (!first) {
      main.appendChild(this.emptyTemplateTarget.content.cloneNode(true))
      return
    }
    const img = document.createElement("img")
    img.className = "pgallery__main-img"
    img.alt = ""
    img.src = first.dataset.mainUrl || first.querySelector("[data-role='thumb']").src
    main.appendChild(img)
    const badge = first.querySelector("[data-role='primary-badge']").cloneNode(true)
    badge.className = "badge badge-accent pgallery__main-badge"
    main.appendChild(badge)
  }

  #newItem(file) {
    const fragment = this.itemTemplateTarget.content.cloneNode(true)
    const item = fragment.querySelector("li")
    const url = URL.createObjectURL(file)
    this.objectUrls.push(url)
    item.dataset.entry = ""
    item.dataset.mainUrl = url
    item.classList.add("is-uploading")
    const thumb = item.querySelector("[data-role='thumb']")
    thumb.src = url
    thumb.alt = file.name
    item.querySelector("[data-role='progress']").hidden = false
    this.listTarget.appendChild(item)
    return item
  }

  #upload(file, item) {
    const data = new FormData()
    data.append("file", file)
    const xhr = new XMLHttpRequest()
    item.xhr = xhr
    this.uploads += 1
    xhr.open("POST", this.uploadUrlValue)
    xhr.setRequestHeader("X-CSRF-Token", document.querySelector("meta[name='csrf-token']")?.content || "")
    xhr.setRequestHeader("Accept", "application/json")
    xhr.upload.addEventListener("progress", (event) => {
      if (!event.lengthComputable) return
      item.querySelector("[data-role='progress-bar']").style.width = `${Math.round((event.loaded / event.total) * 100)}%`
    })
    xhr.addEventListener("loadend", () => {
      this.uploads -= 1
      item.xhr = null
      item.classList.remove("is-uploading")
      item.querySelector("[data-role='progress']").hidden = true
      let body = {}
      try { body = JSON.parse(xhr.responseText || "{}") } catch { body = {} }
      if (xhr.status === 201 && body.signed_id) {
        item.dataset.entry = `upload:${body.signed_id}`
      } else if (xhr.status !== 0 || item.isConnected) {
        item.dataset.entry = ""
        item.classList.add("is-failed")
        const error = item.querySelector("[data-role='error']")
        error.textContent = body.error || this.messagesValue.upload_failed
        error.hidden = false
      }
      this.refresh()
    })
    xhr.send(data)
  }

  #toggleSave() {
    const busy = this.uploads > 0
    document.querySelectorAll("#product-form [type='submit'], [type='submit'][form='product-form']").forEach((button) => {
      button.disabled = busy
      if (busy) button.title = this.messagesValue.wait_for_uploads
      else button.removeAttribute("title")
    })
  }

  #showErrors(messages) {
    this.errorsTarget.hidden = messages.length === 0
    this.errorsTarget.textContent = messages.join(" · ")
  }

  #itemOf(event) {
    return event.currentTarget.closest("[data-product-gallery-target='item']")
  }

  #hasFiles(event) {
    return Array.from(event.dataTransfer?.types || []).includes("Files")
  }
}
