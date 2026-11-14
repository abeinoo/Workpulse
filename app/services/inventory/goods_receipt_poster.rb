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
  class GoodsReceiptPoster
    Result = Struct.new(:ok, :receipt, keyword_init: true) do
      def ok? = ok
    end

    def initialize(receipt)
      @receipt = receipt
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

        # Each line's product, with the barcodes and image its cost update
        # validates, in one go — validations still run; lines of the same
        # product share one record, exactly as the cost update needs (it reads
        # the average the previous line just wrote).
        ActiveRecord::Associations::Preloader.new(
          records: @receipt.items.to_a, associations: { product: [ :product_barcodes, { image_attachment: :blob } ] }
        ).call
        @receipt.items.each { |item| post_item(item) }
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
