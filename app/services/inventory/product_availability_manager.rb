module Inventory
  # Product availability per warehouse — the one writer of availability state
  # (ProductWarehouseSetting status and per-warehouse low-stock settings).
  #
  #   add_many     Not Configured -> Active for products in ONE warehouse (bulk,
  #                all-or-nothing; pairs that already have a row are skipped
  #                and reported — an Inactive pair is reactivated, never re-added)
  #   save_settings  the product page's branch card: a pair's low-stock level /
  #                reorder quantity. A sales branch pair with no row is Included
  #                by default — its first save creates the row; anything else
  #                must already be Active
  #   exclude      the product page's branch card: Included -> Excluded, reason
  #                required. In a sales branch warehouse, Excluded IS the
  #                Inactive state (same row, same rules); without a row one is
  #                created Inactive. Undone with reactivate (settings kept)
  #   update       an Active pair's low-stock settings
  #   deactivate   Active -> Inactive, reason required; settings kept;
  #                returns the pair's dependency summary (N5: allowed with
  #                stock or open operations — the summary is the warning)
  #   reactivate   Inactive -> Active with the kept settings
  #   dependencies read-only dependency summary of a pair
  #
  # Every call takes ids, loads them within the actor's business, authorizes
  # through ProductWarehouseSettingPolicy (manage_product_availability + the
  # actor's warehouse scope), locks what it changes, and writes a fail-closed
  # audit entry (log_audit!) per changed pair in the same transaction: if any
  # entry cannot be written, nothing changes.
  #
  # A product whose stock quantity is not tracked gets no NEW availability row
  # (2026-11-20); rows it already has are kept as they are, with no low-stock
  # settings (0 / 0). There is no product-level value to read or write, and no
  # pair is created anywhere but the requested warehouse.
  class ProductAvailabilityManager
    include AuditLoggable

    Result = Struct.new(:ok, :record, :records, :skipped, :dependencies, :error, keyword_init: true) do
      def ok? = ok
    end

    OPEN_PURCHASE_REQUEST_STATUSES = %w[draft pending_approval approved partially_received].freeze
    OPEN_STOCK_ISSUE_STATUSES      = %w[draft pending_approval approved].freeze
    OPEN_STOCK_COUNT_STATUSES      = %w[draft in_progress completed].freeze

    def initialize(actor:)
      @actor = actor
    end

    # A refusal in words, prefixed with the warehouse it concerns
    # ("Main: …") — the product page, the warehouse Products tab and the
    # product Edit page's one Save say it the same way.
    def self.message(code, warehouse = nil)
      text = I18n.t("product_availability.errors.#{code}", warehouse: warehouse&.name,
                                                             default: I18n.t("product_availability.errors.invalid"))
      warehouse ? I18n.t("product_availability.errors.for_product", product: warehouse.name, message: text) : text
    end

    # items: [{ product_id:, low_stock_level:, reorder_quantity:, receive_low_stock_notification: }]
    def add_many(warehouse_id:, items:, source: "manual")
      return failure(:not_authorized) if @actor.nil?

      items = Array(items).map { |item| item.to_h.symbolize_keys }
      return failure(:no_items) if items.empty?
      return failure(:duplicate_product) if items.map { |i| i[:product_id].to_s }.uniq.size != items.size

      batch_id = SecureRandom.uuid
      ActiveRecord::Base.transaction do
        warehouse = Warehouse.operational.where(business_id: @actor.business_id).lock.find_by(id: warehouse_id)
        return failure(:not_authorized) unless warehouse && policy(warehouse).manage?
        return failure(:inactive_warehouse) unless warehouse.active?

        products = business_products.where(id: items.map { |i| i[:product_id] }).index_by { |p| p.id.to_s }
        return failure(:invalid_product) unless products.size == items.size

        existing = ProductWarehouseSetting.where(warehouse_id: warehouse.id, product_id: products.values.map(&:id))
                                          .index_by(&:product_id)
        # Validate every item before writing any row: a refusal never leaves
        # part of the batch behind.
        planned = []
        skipped = []
        items.each do |item|
          product = products[item[:product_id].to_s]
          if (row = existing[product.id])
            skipped << row
            next
          end
          # Stock quantity not tracked: no new availability configuration.
          return failure(:untracked_product, product) unless product.track_inventory?

          settings = settings_for(product, item)
          # The refused row's product goes back as the record, so the caller
          # can name the row that stopped the batch.
          return failure(settings, product) if settings.is_a?(Symbol)

          planned << [ product, settings ]
        end

        created = planned.map { |product, settings| create_row!(product, warehouse, settings, batch_id, source) }
        Result.new(ok: true, records: created, skipped: skipped)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, AuditLoggable::AuditWriteFailed => e
      failure(error_code(e))
    end

    def update(setting_id:, low_stock_level:, reorder_quantity:, receive_low_stock_notification:)
      with_row(setting_id) do |row|
        return failure(:inactive, row) unless row.status_active?

        settings = settings_for(row.product, low_stock_level: low_stock_level, reorder_quantity: reorder_quantity,
                                             receive_low_stock_notification: receive_low_stock_notification)
        return failure(settings, row) if settings.is_a?(Symbol)

        changes = settings.each_with_object({}) do |(key, value), diff|
          diff[key.to_s] = [ row.public_send(key), value ] if row.public_send(key) != value
        end
        return failure(:unchanged, row) if changes.empty?

        row.update!(updated_by: @actor, **settings)
        log_audit!(actor: @actor, auditable: row, action: "availability_update", changes: changes,
                   metadata: { product_id: row.product_id, warehouse_id: row.warehouse_id })
        Result.new(ok: true, record: row)
      end
    end

    def deactivate(setting_id:, reason:)
      reason = reason.to_s.strip.presence
      return failure(:reason_required) unless reason

      with_row(setting_id) do |row|
        return failure(:already_inactive, row) unless row.status_active?

        deactivate_row!(row, reason)
      end
    end

    def reactivate(setting_id:, reason: nil)
      reason = reason.to_s.strip.presence
      with_row(setting_id) do |row|
        return failure(:already_active, row) if row.status_active?
        return failure(:inactive_warehouse, row) unless row.warehouse.active?

        row.update!(status: "active", status_reason: reason, status_changed_at: Time.current,
                    status_changed_by: @actor, updated_by: @actor)
        log_audit!(actor: @actor, auditable: row, action: "availability_reactivate",
                   changes: { "status" => %w[inactive active] },
                   metadata: { product_id: row.product_id, warehouse_id: row.warehouse_id, reason: reason,
                               kept_settings: { low_stock_level: row.low_stock_level.to_s, reorder_quantity: row.reorder_quantity.to_s,
                                                receive_low_stock_notification: row.receive_low_stock_notification } }.compact)
        Result.new(ok: true, record: row)
      end
    end

    # The product page's branch card. Locks the warehouse row, then the pair's
    # row (the order every writer here uses after it). Notifications keep the
    # row's stored preference (a new row: on) — the threshold is the visible
    # control: 0 means no low-stock detection for that pair.
    def save_settings(product_id:, warehouse_id:, low_stock_level:, reorder_quantity:)
      with_pair(product_id, warehouse_id) do |product, warehouse, row|
        values = { low_stock_level: low_stock_level, reorder_quantity: reorder_quantity }
        if row
          return failure(:inactive, warehouse) unless row.status_active?

          settings = settings_for(product, values.merge(receive_low_stock_notification: row.receive_low_stock_notification))
          return failure(settings, warehouse) if settings.is_a?(Symbol)

          changes = settings.each_with_object({}) do |(key, value), diff|
            diff[key.to_s] = [ row.public_send(key), value ] if row.public_send(key) != value
          end
          return failure(:unchanged, warehouse) if changes.empty?

          row.update!(updated_by: @actor, **settings)
          log_audit!(actor: @actor, auditable: row, action: "availability_update", changes: changes,
                     metadata: { product_id: row.product_id, warehouse_id: row.warehouse_id, source: "product_page" })
          Result.new(ok: true, record: row)
        else
          return failure(:not_included_by_default, warehouse) unless warehouse.availability_included_by_default?
          return failure(:inactive_warehouse, warehouse) unless warehouse.active?
          return failure(:untracked_product, warehouse) unless product.track_inventory?

          settings = settings_for(product, values)
          return failure(settings, warehouse) if settings.is_a?(Symbol)

          Result.new(ok: true, record: create_row!(product, warehouse, settings, SecureRandom.uuid, "product_page"))
        end
      end
    end

    # Excludes a product from a sales branch (Included -> Excluded = Inactive).
    # Allowed with stock or open documents (decision N5): the dependency
    # summary is returned and audited; stock stays on the ledger and can still
    # go out, nothing is cancelled. Incoming stock is refused from then on.
    def exclude(product_id:, warehouse_id:, reason:)
      reason = reason.to_s.strip.presence
      return failure(:reason_required) unless reason

      with_pair(product_id, warehouse_id) do |product, warehouse, row|
        if row
          return failure(:already_inactive, warehouse) unless row.status_active?

          deactivate_row!(row, reason)
        else
          return failure(:not_included_by_default, warehouse) unless warehouse.availability_included_by_default?
          return failure(:untracked_product, warehouse) unless product.track_inventory?

          summary = dependency_summary_for(product.id, warehouse.id)
          row = ProductWarehouseSetting.create!(product: product, warehouse: warehouse, status: "inactive",
                                                status_reason: reason, status_changed_at: Time.current,
                                                status_changed_by: @actor, created_by: @actor, updated_by: @actor)
          log_audit!(actor: @actor, auditable: row, action: "availability_deactivate",
                     changes: { "status" => [ nil, "inactive" ] },
                     metadata: { product_id: product.id, warehouse_id: warehouse.id, reason: reason,
                                 dependencies: summary, included_by_default: true })
          Result.new(ok: true, record: row, dependencies: summary)
        end
      end
    end

    # Read-only dependency summary of a pair that may have no row yet.
    def pair_dependencies(product_id:, warehouse_id:)
      return failure(:not_authorized) if @actor.nil?

      warehouse = Warehouse.operational.where(business_id: @actor.business_id).find_by(id: warehouse_id)
      product   = Product.where(business_id: @actor.business_id).find_by(id: product_id)
      return failure(:not_authorized) unless warehouse && product && policy(warehouse).show?

      Result.new(ok: true, dependencies: dependency_summary_for(product.id, warehouse.id))
    end

    # Read-only: what still involves this pair (shown before deactivation).
    def dependencies(setting_id:)
      return failure(:not_authorized) if @actor.nil?

      row = ProductWarehouseSetting.for_business(@actor.business_id).find_by(id: setting_id)
      return failure(:not_authorized) unless row && policy(row).show?

      Result.new(ok: true, record: row, dependencies: dependency_summary(row))
    end

    private

    def with_row(setting_id)
      return failure(:not_authorized) if @actor.nil?

      ActiveRecord::Base.transaction do
        row = ProductWarehouseSetting.for_business(@actor.business_id).lock.find_by(id: setting_id)
        return failure(:not_authorized) unless row && policy(row).manage?

        yield row
      end
    rescue ActiveRecord::RecordInvalid, AuditLoggable::AuditWriteFailed => e
      failure(error_code(e))
    end

    def policy(record) = ProductWarehouseSettingPolicy.new(@actor, record)

    # Loads (business), locks (warehouse, then the pair's row) and authorizes
    # one product/warehouse pair; yields product, warehouse and the row (nil =
    # no row). Any product of the business; an archived product (already out
    # of operations) gets no new row.
    def with_pair(product_id, warehouse_id)
      return failure(:not_authorized) if @actor.nil?

      ActiveRecord::Base.transaction do
        warehouse = Warehouse.operational.where(business_id: @actor.business_id).lock.find_by(id: warehouse_id)
        return failure(:not_authorized, warehouse) unless warehouse && policy(warehouse).manage?

        product = Product.where(business_id: @actor.business_id).find_by(id: product_id)
        return failure(:invalid_product, warehouse) if product.nil?

        # The product page manages only warehouses that include products by
        # default; anything else (unclassified, inactive, non-sales) keeps its
        # row as it is here — it is managed from that warehouse's Products tab.
        return failure(:not_included_by_default, warehouse) unless warehouse.availability_included_by_default?

        row = ProductWarehouseSetting.lock.find_by(product_id: product.id, warehouse_id: warehouse.id)
        return failure(:invalid_product, warehouse) if row.nil? && !product.active?

        yield product, warehouse, row
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, AuditLoggable::AuditWriteFailed => e
      failure(error_code(e))
    end

    def deactivate_row!(row, reason)
      summary = dependency_summary(row)
      row.update!(status: "inactive", status_reason: reason, status_changed_at: Time.current,
                  status_changed_by: @actor, updated_by: @actor)
      log_audit!(actor: @actor, auditable: row, action: "availability_deactivate",
                 changes: { "status" => %w[active inactive] },
                 metadata: { product_id: row.product_id, warehouse_id: row.warehouse_id, reason: reason,
                             dependencies: summary })
      Result.new(ok: true, record: row, dependencies: summary)
    end

    # One new Active row and its fail-closed audit entry (inside the caller's transaction).
    def create_row!(product, warehouse, settings, batch_id, source)
      row = ProductWarehouseSetting.create!(product: product, warehouse: warehouse, status: "active",
                                            created_by: @actor, updated_by: @actor, **settings)
      log_audit!(actor: @actor, auditable: row, action: "availability_add",
                 changes: { "status" => [ nil, "active" ] }.merge(settings.to_h { |k, v| [ k.to_s, [ nil, v ] ] }),
                 metadata: { product_id: product.id, warehouse_id: warehouse.id, batch_id: batch_id, source: source })
      row
    end

    # Transactable products of the actor's business: active, not a parent.
    def business_products = Product.where(business_id: @actor.business_id).transactable

    # The settings to store, or an error Symbol. Untracked products carry no
    # low-stock settings.
    def settings_for(product, item)
      low     = decimal(item[:low_stock_level])
      reorder = decimal(item[:reorder_quantity])
      return :invalid_quantity if low.nil? || reorder.nil? || low.negative? || reorder.negative?
      return :untracked_product_settings if !product.track_inventory? && (low.positive? || reorder.positive?)

      notify = item.key?(:receive_low_stock_notification) ? ActiveModel::Type::Boolean.new.cast(item[:receive_low_stock_notification]) : true
      { low_stock_level: low, reorder_quantity: reorder, receive_low_stock_notification: notify != false }
    end

    def decimal(value)
      return 0.to_d if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def dependency_summary(row) = dependency_summary_for(row.product_id, row.warehouse_id)

    def dependency_summary_for(product_id, warehouse_id)
      on_hand = InventoryMovement.where(product_id: product_id, warehouse_id: warehouse_id)
                                 .pick(Arel.sql(StockLevels::SIGNED_SUM)) || 0
      reserved = StockAvailability.reserved_by(warehouse_ids: [ warehouse_id ], product_ids: [ product_id ])
                                  .values.sum
      {
        on_hand: on_hand.to_d.to_s,
        reserved: reserved.to_d.to_s,
        open_purchase_request_lines:
          PurchaseRequestItem.joins(:purchase_request)
                             .where(product_id: product_id, purchase_requests: { status: OPEN_PURCHASE_REQUEST_STATUSES })
                             .where("purchase_requests.warehouse_id = :w OR purchase_request_items.source_warehouse_id = :w", w: warehouse_id)
                             .count,
        open_stock_issue_lines:
          StockIssueItem.joins(:stock_issue)
                        .where(product_id: product_id, stock_issues: { warehouse_id: warehouse_id, status: OPEN_STOCK_ISSUE_STATUSES })
                        .count,
        draft_goods_receipt_lines:
          GoodsReceiptItem.joins(:goods_receipt)
                          .where(product_id: product_id, goods_receipts: { warehouse_id: warehouse_id, status: "draft" })
                          .count,
        open_stock_count_lines:
          StockCountItem.joins(:stock_count)
                        .where(product_id: product_id, stock_counts: { warehouse_id: warehouse_id, status: OPEN_STOCK_COUNT_STATUSES })
                        .count
      }
    end

    def error_code(exception)
      case exception
      when AuditLoggable::AuditWriteFailed then :audit_failed
      when ActiveRecord::RecordNotUnique   then :already_configured
      else :invalid
      end
    end

    def failure(error, record = nil) = Result.new(ok: false, record: record, error: error)
  end
end
