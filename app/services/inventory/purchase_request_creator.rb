module Inventory
  # Creates one Purchase Request PER DESTINATION WAREHOUSE from a flat list of
  # selected items — checked rows from the Low Stock Alerts review modal, or
  # the lines of the general "إنشاء طلب شراء" form (one warehouse chosen for
  # the whole request, so a single request). Never posts inventory — a
  # Purchase Request is a request-only document; stock only moves later, at
  # Goods Receipt confirmation.
  #
  # The warehouse belongs to the request (PurchaseRequest#warehouse): every
  # item must name one, and items are grouped by it. The supplier belongs to
  # each line (PurchaseRequestItem#supplier) and is optional — product.
  # default_supplier is only the suggestion, so one request may buy from
  # several suppliers. The request-level supplier_id is a legacy column and is
  # never written here. All groups are created inside a single transaction: if
  # any group fails to save, the whole batch rolls back — no partially-created
  # set of requests.
  #
  # idempotency_key covers the WHOLE batch, not one request: a retried
  # submission with the same key returns the previously created requests
  # instead of creating new ones (checked up front, before the transaction
  # opens). The DB backstop is a partial unique index on (idempotency_key,
  # COALESCE(warehouse_id, 0)) for requests without a request-level supplier —
  # one request per warehouse per batch key.
  #
  # Server-side guards (never trust the picker): every product must be a
  # transactable product of this business, every supplier must belong to this
  # business, every warehouse must belong to this business AND be one the
  # actor is assigned to (warehouse-scoped users) — and, from the general form,
  # must be active — and a product may appear only once per request (a
  # repeated line must be edited, not duplicated, whatever its supplier).
  #
  # The responsible employee (PurchaseRequest#responsible_employee) is OPTIONAL
  # here — it can be assigned later (PurchaseRequestResponsibleAssigner), and is
  # never defaulted to the actor. When given, the whole batch shares it and it
  # must be eligible: an active employee of this business with the purchasing
  # permission and an active custody account, decided by Finance & Sales through
  # Inventory::PurchaseRequestAdvanceEffects.responsible_custody_account_id.
  # Without one a request cannot be funded by an advance or paid from custody.
  class PurchaseRequestCreator
    include AuditLoggable

    Result = Struct.new(:ok, :purchase_requests, :error, keyword_init: true) do
      def ok? = ok
    end

    # items: array of { product_id:, quantity:, unit_price:, warehouse_id:, supplier_id: (optional), notes: (optional) }
    # notes: request-level notes, applied to every request in the batch.
    # require_active_warehouse: the general form offers active warehouses
    # only. Off for the Low Stock review modal, whose rows come from the stock
    # report (any warehouse of the business, still within the actor's scope).
    def initialize(business, actor:, items:, responsible_employee_id: nil, source: nil, idempotency_key: nil, notes: nil,
                   require_active_warehouse: false)
      @business        = business
      @responsible_employee_id = responsible_employee_id.presence
      @actor           = actor
      @items           = Array(items).map(&:symbolize_keys)
      @source          = source
      @idempotency_key = idempotency_key.presence
      @notes           = notes.presence
      @require_active_warehouse = require_active_warehouse
    end

    def call
      return no_items_error if @items.empty?

      existing = find_existing_batch
      return Result.new(ok: true, purchase_requests: existing) if existing&.any?

      return error(:invalid_product)         unless products_allowed?
      return error(:invalid_supplier)        unless suppliers_allowed?
      return error(:missing_warehouse)       if @items.any? { |i| i[:warehouse_id].blank? }
      return error(:unauthorized_warehouse)  unless warehouses_allowed?
      return error(:duplicate_product)       if duplicate_lines?
      return error(:responsible_employee_ineligible) if @responsible_employee_id && !responsible_employee_eligible?

      created = []
      ActiveRecord::Base.transaction do
        @items.group_by { |item| item[:warehouse_id].to_i }.each do |warehouse_id, group_items|
          created << create_request_for_group(warehouse_id, group_items)
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

    def create_request_for_group(warehouse_id, group_items)
      request = PurchaseRequest.new(
        business:         @business,
        warehouse_id:     warehouse_id,
        responsible_employee_id: @responsible_employee_id,
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
          supplier_id:          item[:supplier_id].presence,
          notes:                item[:notes]
        )
      end

      request.save!
      log_audit(
        actor: @actor, auditable: request, action: "create",
        metadata: {
          source: @source,
          warehouse_id: warehouse_id,
          responsible_employee_id: request.responsible_employee_id,
          supplier_ids: group_items.filter_map { |item| item[:supplier_id].presence&.to_i }.uniq,
          item_count: request.items.size,
          total: request.total_amount.to_s,
          product_ids: group_items.map { |item| item[:product_id] }
        }
      )
      request
    end

    def responsible_employee_eligible?
      Inventory::PurchaseRequestAdvanceEffects.responsible_custody_account_id(
        business_id: @business.id, user_id: @responsible_employee_id
      ).present?
    end

    # Blank is fine (a line whose supplier isn't decided yet); anything given
    # must be one of this business's suppliers.
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

    # Every warehouse must be in scope (presence is checked before this).
    def warehouses_allowed?
      ids = @items.map { |item| item[:warehouse_id].to_s }.uniq

      candidates = @require_active_warehouse ? @business.warehouses.active : @business.warehouses
      allowed = candidates.where(id: ids).pluck(:id).map(&:to_s)
      scoped  = @actor.inventory_warehouse_ids
      allowed &= scoped.map(&:to_s) if scoped
      (ids - allowed).empty?
    end

    # One product per request = one product per warehouse group.
    def duplicate_lines?
      keys = @items.map { |item| [ item[:product_id].to_s, item[:warehouse_id].to_s ] }
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
