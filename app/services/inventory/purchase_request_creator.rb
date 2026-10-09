module Inventory
  # Creates one Purchase Request PER SUPPLIER from a flat list of selected
  # items — checked rows from the Low Stock Alerts table, or the lines of the
  # general "إنشاء طلب شراء" form (any transactable product, low stock or
  # not; there it's always a single supplier, so a single request). Never posts
  # inventory — a Purchase Request is a request-only document; stock only
  # moves later, at Goods Receipt confirmation.
  #
  # Each item carries the supplier the user settled on (product.default_supplier
  # is only the suggestion) — or none: the supplier is optional at every stage
  # of a request. Items are grouped by supplier_id (blank =
  # one "no supplier" group) and one PurchaseRequest + its PurchaseRequestItems
  # is created per group, all inside a single transaction: if any group fails
  # to save, the whole batch rolls back — no partially-created set of requests.
  #
  # idempotency_key covers the WHOLE batch, not one request: a retried
  # submission with the same key returns the previously created requests
  # instead of creating new ones (checked up front, before the transaction
  # opens). The DB backstop is a unique index on (idempotency_key,
  # supplier_id) — which still allows several suppliers to legitimately share
  # one batch key — plus a partial index allowing at most one no-supplier
  # request per key (NULLs never collide in the first one).
  #
  # Server-side guards (never trust the picker): every product must be a
  # transactable product of this business, every source warehouse must belong
  # to this business AND be one the actor is assigned to (warehouse-scoped
  # users) — and, from the general form, must be present and active — and a
  # product may appear only once per warehouse in a batch — a
  # repeated line must be edited, not duplicated.
  class PurchaseRequestCreator
    include AuditLoggable

    Result = Struct.new(:ok, :purchase_requests, :error, keyword_init: true) do
      def ok? = ok
    end

    # items: array of { product_id:, quantity:, unit_price:, supplier_id: (optional), source_warehouse_id: (optional), notes: (optional) }
    # notes: request-level notes, applied to every request in the batch.
    # require_warehouse: every line must name an ACTIVE, accessible warehouse
    # (the general form). Off for the Low Stock review modal, whose total-stock
    # alerts legitimately carry no warehouse.
    def initialize(business, actor:, items:, source: nil, idempotency_key: nil, notes: nil, require_warehouse: false)
      @business        = business
      @actor           = actor
      @items           = Array(items).map(&:symbolize_keys)
      @source          = source
      @idempotency_key = idempotency_key.presence
      @notes           = notes.presence
      @require_warehouse = require_warehouse
    end

    def call
      return no_items_error if @items.empty?

      existing = find_existing_batch
      return Result.new(ok: true, purchase_requests: existing) if existing&.any?

      return error(:invalid_product)         unless products_allowed?
      return error(:invalid_supplier)        unless suppliers_allowed?
      return error(:missing_warehouse)       if @require_warehouse && @items.any? { |i| i[:source_warehouse_id].blank? }
      return error(:unauthorized_warehouse)  unless warehouses_allowed?
      return error(:duplicate_product)       if duplicate_lines?

      created = []
      ActiveRecord::Base.transaction do
        @items.group_by { |item| item[:supplier_id].presence&.to_i }.each do |supplier_id, group_items|
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
        notes:            @notes,
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
          supplier_id: supplier_id,
          item_count: request.items.size,
          total: request.total_amount.to_s,
          product_ids: group_items.map { |item| item[:product_id] }
        }
      )
      request
    end

    # Blank is fine (a no-supplier draft); anything given must be one of this
    # business's suppliers.
    def suppliers_allowed?
      ids = @items.filter_map { |item| item[:supplier_id].presence&.to_s }.uniq
      return true if ids.empty?

      @business.suppliers.where(id: ids).count == ids.size
    end

    def products_allowed?
      ids = @items.map { |item| item[:product_id].to_s }.uniq
      return false if ids.any?(&:blank?)

      @business.products.transactable.where(id: ids).count == ids.size
    end

    # A given warehouse must be in scope. Blank is only reachable when
    # require_warehouse is off (the Low Stock modal's total-stock alerts).
    def warehouses_allowed?
      ids = @items.filter_map { |item| item[:source_warehouse_id].presence&.to_s }.uniq
      return true if ids.empty?

      candidates = @require_warehouse ? @business.warehouses.active : @business.warehouses
      allowed = candidates.where(id: ids).pluck(:id).map(&:to_s)
      scoped  = @actor.inventory_warehouse_ids
      allowed &= scoped.map(&:to_s) if scoped
      (ids - allowed).empty?
    end

    def duplicate_lines?
      keys = @items.map { |item| [ item[:product_id].to_s, item[:source_warehouse_id].presence.to_s ] }
      keys.uniq.size != keys.size
    end

    def error(key)
      Result.new(ok: false, error: I18n.t("inventory.purchase_requests.errors.#{key}"))
    end

    def no_items_error
      Result.new(ok: false, error: I18n.t("inventory.purchase_requests.errors.no_items"))
    end
  end
end
