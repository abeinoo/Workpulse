# One product identity everywhere a product is listed: a small, fixed-size
# thumbnail (the product's Active Storage image, fitted — never cropped or
# stretched) beside its name, with the SKU as secondary text when asked.
#
#   product_identity(product, link: inventory_product_path(product))
#   product_identity(product, size: :md, sku: true)
#   product_thumbnail(product, size: :lg)
#
# Missing image → a CSS placeholder icon (no extra markup). An image that fails
# to load is swapped for the same placeholder by one capture-phase listener in
# application.js — a broken image is never shown.
#
# Performance: the image is read only when it was PRELOADED with the product
# (Product.with_attached_image, or includes(product: { image_attachment: :blob })).
# URLs point at the tracked :thumb variant, generated lazily once per product;
# building them runs no query. <img> is lazy-loaded and has fixed dimensions.
# In the test environment a product whose image wasn't preloaded raises, so a
# missing preload (an N+1 on a long table) fails the specs instead of shipping.
module ProductThumbnailHelper
  THUMBNAIL_SIZES = { xs: 28, sm: 36, md: 44, lg: 72 }.freeze

  class ImageNotPreloaded < StandardError; end

  def product_identity(product, size: :sm, sku: false, link: nil, link_class: "link")
    return "—" if product.nil?

    name = link ? link_to(product.name, link, class: link_class) : content_tag(:span, product.name)
    text = content_tag(:span, class: "pident__text") do
      safe_join([ content_tag(:span, name, class: "pident__name"),
                  (content_tag(:span, product.sku, class: "pident__sku", dir: "ltr") if sku && product.sku.present?) ].compact)
    end
    content_tag(:span, safe_join([ product_thumbnail(product, size: size), text ]), class: "pident pident--#{size}")
  end

  def product_thumbnail(product, size: :sm)
    px  = THUMBNAIL_SIZES.fetch(size)
    url = product_thumbnail_url(product, variant: size == :lg ? :large : :thumb)
    return content_tag(:span, "", class: "pthumb pthumb--#{size} pthumb--empty", aria: { hidden: true }) unless url

    content_tag(:span, class: "pthumb pthumb--#{size}") do
      tag.img(src: url, alt: "", width: px, height: px, loading: "lazy", decoding: "async", class: "pthumb__img")
    end
  end

  # The searchable product picker (product_combobox_controller.js): an ARIA
  # combobox over the server product search (Inventory::ProductPickerSearch,
  # `kind` = the list this picker always offered), submitting through a hidden
  # <select> named like the field it replaces, holding only the selected
  # product's <option> (same data-* as before). `select_data` goes on that
  # <select> — the line's existing listeners (change actions, data-product-field).
  #
  #   product_combobox(f, :product_id, selected: f.object.product, select_data: { product_field: true })
  #   product_combobox(nil, :product_id, name: "product_id", selected: @product, kind: "all", blank: t("…all"))
  def product_combobox(form, method = :product_id, selected: nil, kind: "transactable", name: nil, id: nil,
                       blank: nil, placeholder: nil, clearable: true, select_data: {}, input_class: "form-control")
    field_name = form ? form.field_name(method) : (name || method.to_s)
    field_id   = id || (form ? form.field_id(method) : "#{method}-#{SecureRandom.hex(3)}")
    options    = [ content_tag(:option, blank.to_s, value: "") ]
    options << content_tag(:option, "#{selected.name} (#{selected.sku})", { value: selected.id, selected: true }.merge(product_option_data(selected))) if selected

    content_tag(:div, class: "pcombo", data: { controller: "product-combobox",
                                               product_combobox_url_value: inventory_product_search_path,
                                               product_combobox_kind_value: kind,
                                               product_combobox_clearable_value: clearable,
                                               product_combobox_loading_value: t("inventory.product_picker.loading"),
                                               product_combobox_empty_value: t("inventory.product_picker.empty") }) do
      safe_join([
        content_tag(:select, safe_join(options), name: field_name, id: "#{field_id}-select", hidden: true, tabindex: -1,
                    class: "pcombo__select", aria: { hidden: true },
                    data: select_data.merge(product_combobox_target: "select")),
        content_tag(:div, class: "pcombo__control") do
          safe_join([
            content_tag(:span, "", class: "pcombo__thumb", data: { product_combobox_target: "thumb" }),
            tag.input(type: "text", id: field_id, class: "#{input_class} pcombo__input", autocomplete: "off", role: "combobox",
                      placeholder: placeholder || t("inventory.product_picker.placeholder"),
                      aria: { autocomplete: "list", expanded: false, controls: "#{field_id}-listbox" },
                      data: { product_combobox_target: "input",
                              action: "input->product-combobox#search focus->product-combobox#open " \
                                      "click->product-combobox#open keydown->product-combobox#keydown" }),
            (button_tag("×", type: "button", class: "pcombo__clear", hidden: true,
                        aria: { label: t("inventory.product_picker.clear") },
                        data: { product_combobox_target: "clear", action: "product-combobox#clear" }) if clearable)
          ].compact)
        end,
        content_tag(:ul, "", id: "#{field_id}-listbox", class: "pcombo__listbox", role: "listbox", hidden: true,
                    data: { product_combobox_target: "listbox" })
      ])
    end
  end

  # The selected <option>'s data — the same keys lib/product_option.js writes.
  def product_option_data(product)
    barcodes = product.association(:product_barcodes).loaded? ? product.product_barcodes.map(&:barcode) : []
    { data: { name: product.name, sku: product.sku, barcode: product.association(:product_barcodes).loaded? ? product.barcode : nil,
              barcodes: barcodes.join("|").presence, default_supplier_id: product.default_supplier_id,
              thumb: product_thumbnail_url(product, preloaded_only: true) }.compact }
  end

  # The variant URL, or nil without a (usable) image. No query when preloaded.
  # preloaded_only: for optional enhancements (dropdown options) — a product
  # whose image wasn't preloaded simply gets no URL, never a query.
  def product_thumbnail_url(product, variant: :thumb, preloaded_only: false)
    return nil if product.nil?
    return nil if preloaded_only && !product.association(:image_attachment).loaded?

    unless product.association(:image_attachment).loaded?
      raise ImageNotPreloaded, "Product##{product.id} image not preloaded (use with_attached_image)" if Rails.env.test?

      Rails.logger.warn("[ProductThumbnailHelper] Product##{product.id} image not preloaded")
    end
    image = product.image
    return nil unless image.attached? && image.blob&.variable?

    url_for(image.variant(AttachmentHelper::PRODUCT_IMAGE_VARIANTS.fetch(variant)))
  rescue ImageNotPreloaded
    raise
  rescue StandardError => e
    Rails.logger.warn("[ProductThumbnailHelper] thumbnail for Product##{product&.id} failed: #{e.message}")
    nil
  end
end
