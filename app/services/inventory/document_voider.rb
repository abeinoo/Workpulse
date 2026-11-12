module Inventory
  # Reverses ("voids") a posted inventory document — goods receipt, stock issue,
  # stock transfer, or stock adjustment — the accounting-correct way:
  #
  #   * the original document and its movements are never touched;
  #   * compensating movements (reason: :reversal, source: the document) undo its
  #     stock effect;
  #   * void metadata (who / when / why) is recorded;
  #   * every affected product's cost is recomputed from surviving history.
  #
  # Guards: a document can't be voided twice, a reason is required, and a void is
  # refused if reversing it would drive any warehouse negative (e.g. receipt goods
  # already issued out) — that would create an impossible stock state.
  #
  # The affected products are row-locked (StockAvailability.lock_products!)
  # after the document and before the on-hand check, so a concurrent issue,
  # transfer or adjustment can't consume the stock the reversal needs between
  # the check and the compensating OUT movement.
  #
  # A stock-count adjustment is voided only by reopening its count
  # (Inventory::StockCountReopener passes stock_count_reopen: true) — voiding it
  # alone would leave the count "approved" with no stock effect.
  #
  # audit: true writes a "void" audit entry on the document (stock adjustments;
  # GoodsReceiptVoider audits the receipt itself).
  class DocumentVoider
    include AuditLoggable

    Result = Struct.new(:ok, :document, keyword_init: true) do
      def ok? = ok
    end

    def initialize(document, user:, reason:, audit: false, stock_count_reopen: false)
      @document           = document
      @user               = user
      @reason             = reason.to_s.strip
      @audit              = audit
      @stock_count_reopen = stock_count_reopen
    end

    # The document row is locked (and reloaded) before any guard runs, inside the
    # one transaction that also writes the reversal (BUG-017): a concurrent second
    # void waits for the first to commit, then sees it voided — and the stock it
    # checks is the stock after the first void — so it is refused and writes
    # nothing. Callers that already hold the lock (GoodsReceiptVoider) re-lock the
    # same row harmlessly.
    def call
      ActiveRecord::Base.transaction do
        @document.lock!
        StockAvailability.lock_products!(@document.affected_products.map(&:id))
        next failure unless voidable?

        @document.reversal_entries.each do |entry|
          @document.inventory_movements.create!(
            entry.merge(business: @document.business, reason: :reversal,
                        occurred_on: BusinessDay.current(context: @document.business))
          )
        end

        @document.update!(voided_at: Time.current, voided_by: @user, void_reason: @reason)

        @document.affected_products.each { |product| ProductCostRecalculator.new(product).recompute! }

        if @audit
          log_audit(actor: @user, auditable: @document, action: "void",
                    changes: { voided_at: [ nil, @document.voided_at.iso8601 ] },
                    metadata: { reason: @reason, reversal: @document.reversal_entries.map { |e| reversal_audit(e) } })
        end

        Result.new(ok: true, document: @document)
      end
    end

    private

    # The existing guards, in their original order and with their original
    # messages, on the locked row.
    def voidable?
      if @document.voided?
        @document.errors.add(:base, :already_voided)
        return false
      end

      if @reason.blank?
        @document.errors.add(:void_reason, :blank)
        return false
      end

      if stock_count_adjustment? && !@stock_count_reopen
        @document.errors.add(:base, :void_via_stock_count_reopen)
        return false
      end

      shortfalls = availability_errors
      shortfalls.each { |attrs| @document.errors.add(:base, :void_would_oversell, **attrs) }
      shortfalls.empty?
    end

    # For each reversal entry that REMOVES stock, confirm the warehouse holds
    # enough to reverse without going negative. Quantities for the same
    # (product, warehouse) are summed so multi-line documents are checked as one.
    def availability_errors
      @document.reversal_entries
               .select { |entry| entry[:direction] == :out }
               .group_by { |entry| [ entry[:product].id, entry[:warehouse].id ] }
               .filter_map do |_, entries|
        product   = entries.first[:product]
        warehouse = entries.first[:warehouse]
        needed    = entries.sum { |entry| entry[:quantity].to_d }
        available = product.stock_in(warehouse)
        next if needed <= available

        { product: product.name, sku: product.sku, warehouse: warehouse.name,
          available: available.to_s, needed: needed.to_s }
      end
    end

    def stock_count_adjustment?
      @document.is_a?(StockAdjustment) && @document.stock_count_id.present?
    end

    def reversal_audit(entry)
      { product_id: entry[:product].id, warehouse_id: entry[:warehouse].id,
        direction: entry[:direction].to_s, quantity: entry[:quantity].to_d.to_s }
    end

    def failure
      Result.new(ok: false, document: @document)
    end
  end
end
