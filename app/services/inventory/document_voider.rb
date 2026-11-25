module Inventory
  # Reverses ("voids") a posted inventory document — goods receipt, stock issue,
  # stock transfer, or stock adjustment — the accounting-correct way:
  #
  #   * the original document and its movements are never touched;
  #   * compensating movements (reason: :reversal, source: the document) undo its
  #     stock effect;
  #   * void metadata (who / when / why) is recorded;
  #   * the void is an event at its own posting time (W2): nothing is
  #     recalculated from history. Voiding a cost-bearing inflow (goods
  #     receipt, opening balance) unblends its cost from the current average
  #     (Inventory::AverageCost, audited); every other void leaves the average
  #     as it is.
  #
  # Removals protect approved reservations (on-hand − removal >= reserved).
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
  # A "void" audit entry is written on the document for stock issues and
  # stock transfers always (BUG-074), and for adjustments when audit: true
  # (GoodsReceiptVoider audits the receipt itself).
  class DocumentVoider
    include AuditLoggable

    Result = Struct.new(:ok, :document, keyword_init: true) do
      def ok? = ok
    end

    def initialize(document, user:, reason:, audit: false, stock_count_reopen: false)
      @document           = document
      @user               = user
      @reason             = reason.to_s.strip
      @audit              = audit || document.is_a?(StockIssue) || document.is_a?(StockTransfer)
      @stock_count_reopen = stock_count_reopen
    end

    # The document row is locked (and reloaded) before any guard runs, inside the
    # one transaction that also writes the reversal (BUG-017): a concurrent second
    # void waits for the first to commit, then sees it voided — and the stock it
    # checks is the stock after the first void — so it is refused and writes
    # nothing. Callers that already hold the lock (GoodsReceiptVoider) re-lock the
    # same row harmlessly.
    def call
      # A stock issue's void is its own operation (void_stock_issues), checked
      # here, not only by the controller. Other document types keep their
      # caller's authorization, unchanged.
      if @document.is_a?(StockIssue) && !StockIssueAuthorization.permits?(@user, :void)
        @document.errors.add(:base, StockIssueAuthorization.message)
        return failure
      end

      # Service-level reach (Phase 2): every warehouse the document touches
      # (both ends of a transfer) — the rule StockTransferPolicy#void? applies.
      # A void of a document in a now-inactive warehouse stays possible: its
      # compensating "reversal" movements are accepted by the ledger.
      unless WarehouseReach.permits?(@user, *document_warehouse_ids)
        @document.errors.add(:base, WarehouseReach.message)
        return failure
      end

      ActiveRecord::Base.transaction do
        @document.lock!
        StockAvailability.lock_products!(@document.affected_products.map(&:id))
        next failure unless voidable?

        next failure unless reservations_protected?

        post_reversal!
        @document.update!(voided_at: Time.current, voided_by: @user, void_reason: @reason)

        write_void_audit if @audit

        Result.new(ok: true, document: @document)
      end
    rescue AuditLoggable::AuditWriteFailed
      @document.errors.add(:base, @void_audit_failed ? :void_audit_failed : :average_cost_audit_failed)
      failure
    end

    private

    # A stock issue's "void" entry is mandatory (fail-closed): if it cannot be
    # written, the reversal and the void roll back together. Other document
    # types keep the fail-open entry they had.
    def write_void_audit
      attributes = { actor: @user, auditable: @document, action: "void",
                     changes: { voided_at: [ nil, @document.voided_at.iso8601 ] },
                     metadata: { reason: @reason, reversal: @document.reversal_entries.map { |e| reversal_audit(e) } } }
      return log_audit(**attributes) unless @document.is_a?(StockIssue)

      @void_audit_failed = true
      log_audit!(**attributes)
      @void_audit_failed = false
    end

    # The existing guards, in their original order and with their original
    # messages, on the locked row.
    def voidable?
      if @document.voided?
        @document.errors.add(:base, :already_voided)
        return false
      end

      # Only a posted (approved) transfer has movements to reverse; a draft
      # or pending transfer is cancelled instead, a rejected / cancelled one
      # never moved anything (Inventory::StockTransferCancellation).
      if @document.is_a?(StockTransfer) && !@document.approved?
        @document.errors.add(:base, :void_not_posted)
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

    def post_reversal!
      occurred = BusinessDay.current(context: @document.business)
      @document.reversal_entries.each do |entry|
        next unless entry[:quantity].to_d.positive?

        on_hand_before = entry[:product].current_stock if cost_bearing_reversal?(entry)
        movement = @document.inventory_movements.create!(
          entry.merge(business: @document.business, reason: :reversal, occurred_on: occurred)
        )
        next unless cost_bearing_reversal?(entry)

        AverageCost.new(entry[:product], actor: @user).reverse_inflow!(
          quantity: entry[:quantity], unit_cost: entry[:unit_cost], on_hand_before: on_hand_before,
          source: @document, movement: movement
        )
      end
    end

    def cost_bearing_reversal?(entry)
      return false unless entry[:direction] == :out

      @document.is_a?(GoodsReceipt) || (@document.is_a?(StockAdjustment) && @document.cost_bearing?)
    end

    def reservations_protected?
      @document.reversal_entries.select { |e| e[:direction] == :out }
               .group_by { |e| e[:warehouse] }.all? do |warehouse, entries|
        removals = entries.group_by { |e| e[:product].id }.transform_values { |list| list.sum { |e| e[:quantity].to_d } }
        StockAvailability.protect_reservations!(@document, warehouse: warehouse, removals: removals)
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

    def document_warehouse_ids
      %i[warehouse_id source_warehouse_id destination_warehouse_id]
        .select { |attribute| @document.respond_to?(attribute) }
        .map { |attribute| @document.public_send(attribute) }
    end
  end
end
