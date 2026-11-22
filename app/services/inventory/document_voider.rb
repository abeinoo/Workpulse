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
  # Packaging (Decision 5): an inflow's sealed packages still free leave as
  # packages, the rest of its quantity leaves as base quantity (loose first,
  # fewest packages opened) — never resealed; an outflow's packages come back
  # as the same packages and its base quantity comes back loose; a stock
  # count's packaging corrections are negated. Removals protect approved
  # reservations (on-hand − removal >= reserved).
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
      ActiveRecord::Base.transaction do
        @document.lock!
        StockAvailability.lock_products!(@document.affected_products.map(&:id))
        next failure unless voidable?

        next failure unless reservations_protected?

        post_reversal!
        @document.update!(voided_at: Time.current, voided_by: @user, void_reason: @reason)

        if @audit
          log_audit(actor: @user, auditable: @document, action: "void",
                    changes: { voided_at: [ nil, @document.voided_at.iso8601 ] },
                    metadata: { reason: @reason, reversal: @document.reversal_entries.map { |e| reversal_audit(e) } })
        end

        Result.new(ok: true, document: @document)
      end
    rescue AuditLoggable::AuditWriteFailed
      @document.errors.add(:base, :average_cost_audit_failed)
      failure
    rescue Packaging::Refused => e
      @document.errors.add(:base, :packaging_refused, message: e.message)
      failure
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

    def post_reversal!
      entries  = @document.reversal_entries
      occurred = BusinessDay.current(context: @document.business)
      session  = Packaging::Session.new(business: @document.business, product_ids: entries.map { |e| e[:product].id },
                                        warehouse_ids: entries.map { |e| e[:warehouse].id })
      movements = entries.map do |entry|
        # A packaging-only stock-count line moved no quantity: nothing to
        # reverse in the ledger, only its packaging corrections (below).
        next [ entry, nil ] unless entry[:quantity].to_d.positive?

        on_hand_before = entry[:product].current_stock if cost_bearing_reversal?(entry)
        movement = @document.inventory_movements.create!(
          entry.merge(business: @document.business, reason: :reversal, occurred_on: occurred)
        )
        if cost_bearing_reversal?(entry)
          AverageCost.new(entry[:product], actor: @user).reverse_inflow!(
            quantity: entry[:quantity], unit_cost: entry[:unit_cost], on_hand_before: on_hand_before,
            source: @document, movement: movement
          )
        end
        [ entry, movement ]
      end

      original = InventoryPackagingEntry.where(source: @document).to_a.group_by { |e| [ e.product_id, e.warehouse_id ] }
      movements.group_by { |entry, _| [ entry[:product].id, entry[:warehouse].id ] }.each do |(product_id, warehouse_id), group|
        product = group.first.first[:product]
        recorded = original.fetch([ product_id, warehouse_id ], [])
        session.apply!(product: product, warehouse_id: warehouse_id, source: @document, occurred_on: occurred,
                       movement: group.filter_map(&:last).first) do |plan|
          reverse_packaging(plan, group.map(&:first), recorded)
        end
      end
    end

    def reverse_packaging(plan, entries, recorded)
      out_quantity = entries.select { |e| e[:direction] == :out }.sum { |e| e[:quantity].to_d }
      in_quantity  = entries.select { |e| e[:direction] == :in }.sum { |e| e[:quantity].to_d }
      corrections  = recorded.select { |e| e.kind == "count_correction" }
      position_of  = ->(entry) { plan.structure.level(entry.packaging_level_id)&.position || -1 }

      if corrections.any?
        # A stock count reopened: its counted packaging is taken back exactly.
        corrections.each { |e| plan.negate("count_correction", position_of.(e), e.package_delta) }
        plan.adjust_total(in_quantity - out_quantity)
        return
      end

      if out_quantity.positive?
        arrived = recorded.select { |e| e.kind == "moved" && e.package_delta.positive? }
        arrived.each { |e| plan.remove_inflow(position_of.(e), e.package_delta) }
        as_packages = arrived.sum(0.to_d) { |e| e.package_delta * plan.structure.level(e.packaging_level_id).base_quantity }
        plan.take_base(out_quantity - as_packages)
      end

      return unless in_quantity.positive?

      plan.add_base(in_quantity)
      recorded.select { |e| e.kind == "moved" && e.package_delta.negative? }
              .each { |e| plan.negate("moved", position_of.(e), e.package_delta) }
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
  end
end
