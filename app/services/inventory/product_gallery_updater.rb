module Inventory
  # The product image gallery: an ordered list of ProductImage rows, the first
  # being the product's primary image. Two steps, so a user previews new photos
  # before anything changes:
  #
  #   .stage(actor:, file:) — while the user edits: validates one uploaded file
  #     (size; content type detected from its bytes; decodable as an image) and stores it as an
  #     UNATTACHED Active Storage blob on the application's storage service,
  #     returning a signed, expiring, purpose-bound id (STAGE_PURPOSE).
  #
  #   #call — when the product form is saved: applies the submitted list, in
  #     order, of entries "image:<id>" (an existing image of THIS product) and
  #     "upload:<signed id>" (a blob staged by this business, never attached
  #     before). Images left out are removed; the first entry becomes primary.
  #     An unchanged list changes nothing. One transaction (joins the caller's),
  #     the product row locked, one audit entry ("gallery_update").
  #
  # Authorization: ProductPolicy#manage_images? (the product editors).
  class ProductGalleryUpdater
    include AuditLoggable

    Result      = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }
    StageResult = Struct.new(:ok, :signed_id, :filename, :error, keyword_init: true) { def ok? = ok }

    STAGE_PURPOSE = :product_gallery
    STAGE_TTL     = 1.day
    ENTRY         = /\A(image|upload):(.+)\z/

    def self.stage(actor:, file:)
      return StageResult.new(ok: false, error: :not_authorized) unless actor && ProductPolicy.new(actor, Product).manage_images?
      return StageResult.new(ok: false, error: :no_file) unless file.respond_to?(:read) && file.respond_to?(:original_filename)
      return StageResult.new(ok: false, error: :too_large) if file.size > Attachable::DEFAULT_MAX_SIZE

      blob = ActiveStorage::Blob.create_and_upload!(
        io: file, filename: file.original_filename, identify: true,
        metadata: { "staged_for_business_id" => actor.business_id, "staged_by_id" => actor.id }
      )
      # The declared type and the file name can lie, so the image is decoded
      # (Active Storage's image analyzer): a real image has dimensions.
      blob.analyze if Attachable::IMAGE_CONTENT_TYPES.include?(blob.content_type)
      unless Attachable::IMAGE_CONTENT_TYPES.include?(blob.content_type) && blob.metadata["width"].to_i.positive?
        blob.purge
        return StageResult.new(ok: false, error: :invalid_type)
      end

      StageResult.new(ok: true, signed_id: blob.signed_id(purpose: STAGE_PURPOSE, expires_in: STAGE_TTL),
                      filename: blob.filename.to_s)
    end

    def initialize(actor:, product_id:, entries:)
      @actor      = actor
      @product_id = product_id
      @entries    = Array(entries).map(&:to_s).reject(&:blank?)
    end

    def call
      ActiveRecord::Base.transaction do
        product = Product.where(business_id: @actor&.business_id).lock.find_by(id: @product_id)
        return failure(:not_authorized) unless product && ProductPolicy.new(@actor, product).manage_images?

        current = product.images.to_a
        plan = plan_for(current)
        return plan if plan.is_a?(Result)
        return Result.new(ok: true, record: product) if plan.map { |kind, value| kind == :image ? value.id : nil } == current.map(&:id)

        removed = current - plan.select { |kind, _| kind == :image }.map(&:last)
        removed.each(&:destroy!)
        final = plan.each_with_index.map do |(kind, value), index|
          if kind == :image
            value.update!(position: index + 1) if value.position != index + 1
            value
          else
            ProductImage.create!(product: product, business_id: product.business_id, position: index + 1, file: value)
          end
        end

        log_audit(actor: @actor, auditable: product, action: "gallery_update",
                  metadata: { image_ids: final.map(&:id), primary_image_id: final.first&.id,
                              added_image_ids: final.select(&:previously_new_record?).map(&:id),
                              removed_image_ids: removed.map(&:id) })
        Result.new(ok: true, record: product)
      end
    rescue ActiveRecord::RecordInvalid => e
      failure(:invalid_image, e.record)
    end

    private

    # [[:image, ProductImage] | [:upload, ActiveStorage::Blob], ...] in the
    # submitted order, or a failed Result.
    def plan_for(current)
      return failure(:too_many) if @entries.size > ProductImage::MAX_PER_PRODUCT
      return failure(:duplicate) if @entries.uniq.size != @entries.size

      by_id = current.index_by { |image| image.id.to_s }
      @entries.map do |entry|
        kind, value = entry.match(ENTRY)&.captures
        case kind
        when "image"
          by_id[value] ? [ :image, by_id[value] ] : (return failure(:invalid_image))
        when "upload"
          blob = staged_blob(value)
          blob ? [ :upload, blob ] : (return failure(:invalid_upload))
        else
          return failure(:invalid_image)
        end
      end
    end

    # A blob this business staged (signed, unexpired, never attached).
    def staged_blob(signed_id)
      blob = ActiveStorage::Blob.find_signed(signed_id, purpose: STAGE_PURPOSE)
      return nil unless blob
      return nil unless blob.metadata["staged_for_business_id"].to_s == @actor.business_id.to_s
      return nil if blob.attachments.exists?
      return nil unless Attachable::IMAGE_CONTENT_TYPES.include?(blob.content_type)

      blob
    end

    def failure(error, record = nil) = Result.new(ok: false, record: record, error: error)
  end
end
