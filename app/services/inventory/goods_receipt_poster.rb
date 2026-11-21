module Inventory
  # Posts a goods receipt: assigns its number (if not already set), persists it,
  # and for each line item records an IN movement (the stock increase) and rolls
  # the product's moving-average / last-purchase cost forward. All-or-nothing in
  # one transaction so a mid-way failure leaves no partial stock.
  #
  # Posting IS confirming, as far as stock is concerned — a draft receipt has no
  # movements yet, so calling this marks it confirmed. It does not set
  # confirmed_at/confirmed_by or handle a funding source, since it has no actor;
  # Inventory::GoodsReceiptConfirmationService layers that on top when a real
  # user is confirming through the UI. Called directly (no actor) by specs that
  # just need posted stock, and by the confirmation service.
  #
  # A line into a product/warehouse pair whose availability is Inactive is
  # refused (Inventory::IncomingAvailabilityGuard), unless it fulfils a
  # purchase request approved before the deactivation (N6). Such a line needs
  # an actor and writes a fail-closed audit entry; without an actor, or if
  # the entry can't be written, nothing is posted.
  class GoodsReceiptPoster
    include AuditLoggable

    EXCEPTION_AUDIT_ACTION = "receive_into_inactive_pair".freeze

    Result = Struct.new(:ok, :receipt, keyword_init: true) do
      def ok? = ok
    end

    def initialize(receipt, actor: nil)
      @receipt = receipt
      @actor   = actor
    end

    def call
      ActiveRecord::Base.transaction do
        @receipt.receipt_number = NumberSequencer.new(@receipt.business, :goods_receipt).next_number if @receipt.receipt_number.blank?

        unless @receipt.save
          raise ActiveRecord::Rollback
        end

        unless purchase_request_quantities_valid?
          raise ActiveRecord::Rollback
        end

        exception_lines = incoming_availability_exceptions
        raise ActiveRecord::Rollback if exception_lines.nil?

        # Each line's product, with the barcodes and image its cost update
        # validates, in one go — validations still run; lines of the same
        # product share one record, exactly as the cost update needs (it reads
        # the average the previous line just wrote).
        ActiveRecord::Associations::Preloader.new(
          records: @receipt.items.to_a, associations: { product: [ :product_barcodes, Product::IMAGE_PRELOAD ] }
        ).call
        @receipt.items.each { |item| post_item(item) }
        audit_exceptions!(exception_lines)
        @receipt.update_column(:status, "confirmed") if @receipt.draft?
        return Result.new(ok: true, receipt: @receipt)
      end

      Result.new(ok: false, receipt: @receipt)
    end

    private

    # Race-safe "don't over-receive" guard — the one place in the app that
    # actually posts stock, so it's the one place this can be enforced
    # correctly. Locks every referenced PurchaseRequestItem row (SELECT FOR
    # UPDATE, held until this transaction commits) so two receipts confirmed
    # concurrently for the same Purchase Request line serialize instead of
    # both reading the same stale "already received" total. The rows are
    # locked in ascending id order, whatever the receipt's line order, so two
    # receipts sharing several lines always wait on each other in the same
    # order and never deadlock. Each line's quantity is compared summed (a
    # line listed twice counts once). A soft, non-locking version of the same
    # check also runs at draft save time
    # (GoodsReceiptItem#within_remaining_quantity) purely for early UI
    # feedback, and approval refuses paying beyond what can still arrive
    # (Inventory::GoodsReceiptApproval) — this is the only check that's
    # actually race-safe for stock.
    def purchase_request_quantities_valid?
      wanted = @receipt.request_line_quantities
      return true if wanted.empty?

      # ORDER BY id under FOR UPDATE: PostgreSQL locks the rows in that order.
      lines = PurchaseRequestItem.where(id: wanted.keys).order(:id).lock.includes(:product).to_a
      remaining_by_line = PurchaseRequestItem.remaining_quantities(lines) # one query, read under the locks
      lines.all? do |line|
        remaining = remaining_by_line[line.id]
        next true if wanted[line.id] <= remaining

        @receipt.errors.add(:base, :exceeds_remaining_quantity, product: line.product.name, remaining: remaining)
        false
      end
    end

    # Runs under the purchase request line locks taken just before. Returns the
    # lines admitted by the N6 exception, or nil (errors added) when any line
    # into an Inactive pair is refused.
    def incoming_availability_exceptions
      guard = IncomingAvailabilityGuard.new(warehouse_id: @receipt.warehouse_id,
                                            product_ids:  @receipt.items.reject(&:marked_for_destruction?).map(&:product_id))
      exceptions, refused = guard.classify_receipt(@receipt)
      # An exception must name who received the stock; never admitted anonymously.
      refused += exceptions.map(&:setting) if @actor.nil?
      return nil if guard.refuse!(@receipt, refused.uniq)

      exceptions
    end

    # One fail-closed entry per admitted line: AuditWriteFailed propagates and
    # rolls the whole posting back.
    def audit_exceptions!(lines)
      lines.each do |line|
        setting = line.setting
        log_audit!(
          actor: @actor, auditable: @receipt, action: EXCEPTION_AUDIT_ACTION,
          metadata: {
            exception:                    "purchase_request_approved_before_deactivation",
            goods_receipt_id:             @receipt.id,
            receipt_number:               @receipt.receipt_number,
            goods_receipt_item_id:        line.item.id,
            product_id:                   setting.product_id,
            warehouse_id:                 setting.warehouse_id,
            quantity:                     line.item.quantity.to_s,
            purchase_request_id:          line.purchase_request.id,
            purchase_request_item_id:     line.purchase_request_item.id,
            purchase_request_approved_at: line.purchase_request.approved_at.iso8601,
            receipt_approved_at:          @receipt.decided_at.iso8601,
            product_warehouse_setting_id: setting.id,
            deactivated_at:               setting.status_changed_at.iso8601,
            deactivation_reason:          setting.status_reason
          }
        )
      end
    end

    def post_item(item)
      product = item.product
      # Read on-hand *before* this movement so the moving average is correct.
      on_hand_before = product.current_stock

      @receipt.inventory_movements.create!(
        business:    @receipt.business,
        product:     product,
        warehouse:   @receipt.warehouse,
        direction:   :in,
        reason:      :goods_receipt,
        quantity:    item.quantity,
        unit_cost:   item.unit_cost,
        occurred_on: @receipt.received_on
      )

      ProductCostUpdater.new(product).apply_receipt(
        quantity:       item.quantity,
        unit_cost:      item.unit_cost,
        on_hand_before: on_hand_before
      )
    end
  end
end
