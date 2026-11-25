module Inventory
  # The product Edit page's one Save: product details (and barcodes), the image
  # gallery and the per-warehouse availability settings — all or nothing, in
  # ONE transaction.
  #
  # It adds no rule of its own; every section is applied by its existing
  # single writer, called inside this transaction:
  #
  #   product details  Product validations (Measure, Amount, tracking …)
  #   gallery          Inventory::ProductGalleryUpdater
  #   availability     Inventory::ProductAvailabilityManager (authorizes every
  #                    warehouse itself, locks, audits fail-closed)
  #
  # Each section runs in its own savepoint, so a refusal in one (even a
  # database error) leaves the transaction usable and every section's errors
  # are collected for the page; if any section is refused the whole
  # transaction is rolled back — nothing of the submission is saved, audit
  # entries included. Stock, costs and movements are never touched.
  #
  # availability: { "<warehouse id>" => { low_stock_level:, reorder_quantity:,
  #                                       excluded: "0" | "1", reason: } }
  # Only what differs from the stored state is applied: settings that equal
  # the stored ones (or the 0 / 0 default of a pair with no row) write nothing,
  # a ticked Exclude on an included pair excludes it (reason required), an
  # unticked one on an excluded pair includes it again.
  class ProductEditor
    Result = Struct.new(:ok, :product, :availability_errors, :exclusion_errors, keyword_init: true) do
      def ok? = ok
    end

    def initialize(actor:, product_id:, attributes:, gallery: nil, availability: nil)
      @actor        = actor
      @product_id   = product_id
      @attributes   = attributes.to_h.with_indifferent_access
      @gallery      = gallery
      @availability = availability.respond_to?(:to_h) ? availability.to_h : {}
      @availability_errors = {}
      @exclusion_errors    = {}
    end

    def call
      @product = Product.where(business_id: @actor.business_id).includes(:product_barcodes).find(@product_id)
      @product.assign_attributes(@attributes)

      ActiveRecord::Base.transaction do
        section { save_product }
        section { apply_gallery } if @gallery
        apply_availability if @availability.any? && @product.track_inventory?
        raise ActiveRecord::Rollback if failed?
      end
      result
    end

    private

    def failed? = @product.errors.any? || @availability_errors.any? || @exclusion_errors.any?

    def result
      # The refused exclusion's dependency summary, read after the rollback.
      @exclusion_errors.each_value { |error| error[:dependencies] = error[:dependencies].call }
      Result.new(ok: !failed?, product: @product, availability_errors: @availability_errors, exclusion_errors: @exclusion_errors)
    end

    # One savepoint: the block returns true when its section succeeded;
    # otherwise the section's writes are undone at once.
    def section
      ActiveRecord::Base.transaction(requires_new: true) do
        raise ActiveRecord::Rollback unless yield
      end
    end

    def save_product
      @product.save
    rescue ActiveRecord::RecordNotUnique => e
      # A concurrent save took the same barcode (or SKU) after validation.
      @product.errors.add(*(e.message.include?("product_barcodes") ? [ :base, :barcode_taken ] : [ :sku, :taken ]))
      false
    end

    def apply_gallery
      result = ProductGalleryUpdater.new(actor: @actor, product_id: @product.id, entries: @gallery).call
      return true if result.ok?

      @product.errors.add(:base, I18n.t("inventory.products.gallery.errors.#{result.error}", max: Attachable::DEFAULT_MAX_SIZE / 1.megabyte))
      false
    end

    # ── Availability ─────────────────────────────────────────────────────────
    def apply_availability
      manager  = ProductAvailabilityManager.new(actor: @actor)
      warehouses = Warehouse.operational.where(business_id: @actor.business_id, id: @availability.keys).index_by { |w| w.id.to_s }
      rows = ProductWarehouseSetting.where(product_id: @product.id, warehouse_id: warehouses.values.map(&:id)).index_by(&:warehouse_id)

      @availability.each do |warehouse_id, input|
        input = input.respond_to?(:to_unsafe_h) ? input.to_unsafe_h : input.to_h
        input = input.with_indifferent_access
        warehouse = warehouses[warehouse_id.to_s]
        # A warehouse outside the business is never named back to the user.
        next @availability_errors[warehouse_id.to_i] = ProductAvailabilityManager.message(:not_authorized) unless warehouse

        apply_pair(manager, warehouse, rows[warehouse.id], input)
      end
    end

    def apply_pair(manager, warehouse, row, input)
      excluded_now = row.present? && !row.status_active?
      exclude      = input.key?(:excluded) ? input[:excluded].to_s == "1" : excluded_now

      if exclude && !excluded_now
        section do
          result = manager.exclude(product_id: @product.id, warehouse_id: warehouse.id, reason: input[:reason])
          refused_exclusion(manager, warehouse, input, result) unless result.ok?
          result.ok?
        end
      elsif !exclude && excluded_now
        section do
          result = manager.reactivate(setting_id: row.id)
          @availability_errors[warehouse.id] = ProductAvailabilityManager.message(result.error, warehouse) unless result.ok?
          result.ok?
        end
      elsif !exclude && settings_changed?(row, input)
        section do
          result = manager.save_settings(product_id: @product.id, warehouse_id: warehouse.id,
                                         low_stock_level: input[:low_stock_level], reorder_quantity: input[:reorder_quantity])
          ok = result.ok? || result.error == :unchanged
          @availability_errors[warehouse.id] = ProductAvailabilityManager.message(result.error, warehouse) unless ok
          ok
        end
      end
    end

    def refused_exclusion(manager, warehouse, input, result)
      @exclusion_errors[warehouse.id] = { message: ProductAvailabilityManager.message(result.error, warehouse), reason: input[:reason].to_s,
                                          dependencies: -> { manager.pair_dependencies(product_id: @product.id, warehouse_id: warehouse.id).dependencies } }
    end

    # Only fields the card sent; an unparsable value counts as a change (the
    # manager refuses it with its own message).
    def settings_changed?(row, input)
      %i[low_stock_level reorder_quantity].any? do |field|
        next false unless input.key?(field)

        stored = row ? row.public_send(field).to_d : 0.to_d
        submitted = input[field].to_s.strip.empty? ? 0.to_d : BigDecimal(input[field].to_s)
        submitted != stored
      rescue ArgumentError, TypeError
        true
      end
    end
  end
end
