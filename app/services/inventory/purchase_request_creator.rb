module Inventory
  # Creates one Purchase Request PER SUPPLIER from a flat list of selected
  # items (e.g. checked rows from the Low Stock Alerts table). Never posts
  # inventory — a Purchase Request is a request-only document; stock only
  # moves later, at Goods Receipt confirmation.
  #
  # Every item must already carry a resolved supplier_id (the caller — the
  # controller — resolves product.default_supplier_id or the user's
  # review-step choice before calling this). Items are grouped by supplier_id
  # and one PurchaseRequest + its PurchaseRequestItems is created per group,
  # all inside a single transaction: if any group fails to save, the whole
  # batch rolls back — no partially-created set of requests.
  #
  # idempotency_key covers the WHOLE batch, not one request: a retried
  # submission with the same key returns the previously created requests
  # instead of creating new ones (checked up front, before the transaction
  # opens). The DB backstop is a unique index on (idempotency_key,
  # supplier_id) — see the migration — which still allows several suppliers
  # to legitimately share one batch key.
  class PurchaseRequestCreator
    include AuditLoggable

    Result = Struct.new(:ok, :purchase_requests, :error, :missing_supplier_product_ids, keyword_init: true) do
      def ok? = ok
    end

    # items: array of { product_id:, quantity:, unit_price:, supplier_id:, source_warehouse_id: (optional), notes: (optional) }
    def initialize(business, actor:, items:, source: nil, idempotency_key: nil)
      @business        = business
      @actor           = actor
      @items           = Array(items).map(&:symbolize_keys)
      @source          = source
      @idempotency_key = idempotency_key.presence
    end

    def call
      return no_items_error if @items.empty?

      existing = find_existing_batch
      return Result.new(ok: true, purchase_requests: existing) if existing&.any?

      missing = @items.select { |item| item[:supplier_id].blank? }
      return missing_supplier_error(missing) if missing.any?

      created = []
      ActiveRecord::Base.transaction do
        @items.group_by { |item| item[:supplier_id].to_i }.each do |supplier_id, group_items|
          created << create_request_for_group(supplier_id, group_items)
        end
      end

      Result.new(ok: true, purchase_requests: created)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def find_existing_batch
      return nil unless @idempotency_key

      PurchaseRequest.where(business: @business, idempotency_key: @idempotency_key).to_a
    end

    def create_request_for_group(supplier_id, group_items)
      request = PurchaseRequest.new(
        business:         @business,
        supplier_id:      supplier_id,
        created_by:       @actor,
        source:           @source,
        idempotency_key:  @idempotency_key
      )

      group_items.each do |item|
        request.items.build(
          product_id:           item[:product_id],
          quantity:             item[:quantity],
          unit_price:           item[:unit_price],
          source_warehouse_id:  item[:source_warehouse_id],
          notes:                item[:notes]
        )
      end

      request.save!
      log_audit(
        actor: @actor, auditable: request, action: "create",
        metadata: {
          source: @source,
          item_count: request.items.size,
          total: request.total_amount.to_s,
          product_ids: group_items.map { |item| item[:product_id] }
        }
      )
      request
    end

    def no_items_error
      Result.new(ok: false, error: I18n.t("inventory.purchase_requests.errors.no_items"))
    end

    def missing_supplier_error(missing)
      Result.new(
        ok: false,
        error: I18n.t("inventory.purchase_requests.errors.missing_supplier"),
        missing_supplier_product_ids: missing.map { |item| item[:product_id] }
      )
    end
  end
end
