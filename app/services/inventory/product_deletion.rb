module Inventory
  # Permanently deletes a product (BUG-063). Deletion is the exception — a
  # product with any trace is archived instead — so it is refused unless the
  # product is:
  #
  #   * of the actor's business and destroyable by the actor (ProductPolicy#destroy?),
  #   * archived (server-side; the page offers Delete only for archived products),
  #   * free of inventory history (Product#has_inventory_history?: movements,
  #     document lines, stock count lines, barcodes), and
  #   * referenced by nothing else: no warehouse availability row (in ANY
  #     warehouse — deleting one would erase another warehouse's
  #     configuration), purchase request line, laundry consumption, stock issue
  #     import row or legacy variant row. (Before, those last four made the
  #     delete fail with a foreign-key error — a 500.)
  #
  # The row is locked, and a fail-closed audit entry (log_audit!) with a
  # snapshot of the product is written in the same transaction — the entry is
  # the only record that remains, so without it nothing is deleted.
  class ProductDeletion
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, :blockers, keyword_init: true) { def ok? = ok }

    # Tables that reference products.id without a destroy path of their own.
    REFERENCES = {
      warehouse_availability:  "product_warehouse_settings",
      purchase_request_lines:  "purchase_request_items",
      laundry_consumptions:    "laundry_batch_consumptions",
      stock_issue_import_rows: "stock_issue_import_rows",
      legacy_variants:         "product_variants"
    }.freeze

    SNAPSHOT_ATTRIBUTES = %w[id name sku unit_of_measure brand_id product_category_id default_supplier_id
                             track_inventory active archived_at initial_cost_price average_cost_price created_at].freeze

    def initialize(actor:)
      @actor = actor
    end

    def call(product_id:)
      return failure(:not_authorized) if @actor.nil?

      ActiveRecord::Base.transaction do
        product = Product.where(business_id: @actor.business_id).lock.find_by(id: product_id)
        return failure(:not_authorized) unless product && ProductPolicy.new(@actor, product).destroy?
        return failure(:not_archived, product) unless product.archived?
        return failure(:has_history, product) if product.has_inventory_history?

        blockers = blockers_for(product)
        return Result.new(ok: false, record: product, error: :referenced, blockers: blockers) if blockers.any?

        snapshot = product.attributes.slice(*SNAPSHOT_ATTRIBUTES).transform_values { |v| v.is_a?(BigDecimal) ? v.to_s : v }
        product.destroy!
        log_audit!(actor: @actor, auditable: product, action: "destroy", metadata: { product: snapshot })
        Result.new(ok: true, record: product)
      end
    rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey => e
      failure(:referenced, e.try(:record))
    rescue AuditLoggable::AuditWriteFailed
      failure(:audit_failed)
    end

    private

    def blockers_for(product)
      connection = Product.connection
      REFERENCES.filter_map do |key, table|
        next unless connection.table_exists?(table)

        count = connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)} WHERE product_id = #{Integer(product.id)}").to_i
        [ key, count ] if count.positive?
      end.to_h
    end

    def failure(error, record = nil) = Result.new(ok: false, record: record, error: error, blockers: {})
  end
end
