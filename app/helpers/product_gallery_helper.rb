# The Product New / Edit image gallery (_gallery.html.erb, product_gallery_controller.js).
module ProductGalleryHelper
  GalleryItem = Struct.new(:entry, :thumb_url, :main_url, :label, keyword_init: true)

  # The gallery as shown: after a refused save, exactly what the user had
  # (saved images and staged uploads, in their order); otherwise the
  # product's saved images, primary first.
  def product_gallery_items(product)
    if gallery_submitted?
      saved = product.persisted? ? product.images.includes(file_attachment: :blob).index_by { |image| "image:#{image.id}" } : {}
      gallery_entries.filter_map do |entry|
        if (image = saved[entry])
          gallery_item_for_image(image)
        elsif entry.start_with?("upload:") &&
              (blob = ActiveStorage::Blob.find_signed(entry.delete_prefix("upload:"), purpose: Inventory::ProductGalleryUpdater::STAGE_PURPOSE))
          gallery_item_for_blob(entry, blob)
        end
      end
    elsif product.persisted?
      product.images.includes(file_attachment: :blob).map { |image| gallery_item_for_image(image) }
    else
      []
    end
  end

  # The Product Show page's read-only gallery (_show_gallery.html.erb): the
  # product's saved images in their order (the first is the primary image),
  # read from the already-loaded association — preload
  # `images: { file_attachment: :blob }`. An image without a usable file is
  # left out rather than shown broken.
  def product_show_gallery_items(product)
    product.images.filter_map do |image|
      next unless image.file.attached?

      item = gallery_item_for_image(image)
      item if item.main_url && item.thumb_url
    end
  end

  private

  def gallery_item_for_image(image)
    GalleryItem.new(entry: "image:#{image.id}", label: image.file.filename.to_s,
                    thumb_url: product_image_variant_url(image, :gallery_thumb),
                    main_url: product_image_variant_url(image, :gallery))
  end

  def gallery_item_for_blob(entry, blob)
    variant = ->(name) { blob.variable? ? url_for(blob.variant(AttachmentHelper::PRODUCT_IMAGE_VARIANTS.fetch(name))) : nil }
    GalleryItem.new(entry: entry, label: blob.filename.to_s, thumb_url: variant.call(:gallery_thumb), main_url: variant.call(:gallery))
  end
end
