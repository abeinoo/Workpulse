// The client-side twin of ProductThumbnailHelper#product_thumbnail, for
// product lists drawn in JavaScript (searchable product pickers, the Low
// Stock review). Same markup and CSS: a fixed-size box, the lazy-loaded
// variant fitted inside, or the placeholder when there is no image; a failed
// load becomes the placeholder (application.js).
const SIZES = { xs: 28, sm: 36, md: 44 }

export function productThumbnail(url, size = "xs") {
  const box = document.createElement("span")
  box.className = `pthumb pthumb--${size}`
  box.setAttribute("aria-hidden", "true")
  if (!url) {
    box.classList.add("pthumb--empty")
    return box
  }
  const img = document.createElement("img")
  img.className = "pthumb__img"
  img.src = url
  img.alt = ""
  img.width = SIZES[size]
  img.height = SIZES[size]
  img.loading = "lazy"
  img.decoding = "async"
  box.appendChild(img)
  return box
}
