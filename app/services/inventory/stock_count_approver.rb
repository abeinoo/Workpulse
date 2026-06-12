module Inventory
  # Approves a completed physical count: refreshes each line's system quantity from
  # live stock, computes the difference (counted − system), and generates ONE
  # stock-count Inventory Adjustment from the non-zero differences — so the ledger
  # is corrected through the normal adjustment path (full audit trail, voidable).
  # The count is then frozen as "approved".
  #
  # Recomputing the system quantity at approval time guarantees the warehouse ends
  # at exactly the counted quantity and never produces negative stock (a shortfall
  # can't exceed what's on hand).
  class StockCountApprover
    Result = Struct.new(:ok, :count, keyword_init: true) do
      def ok? = ok
    end

    def initialize(count, user:)
      @count = count
      @user  = user
    end

    def call
      unless @count.completed?
        @count.errors.add(:base, :not_completed)
        return failure
      end

      # Segregation of duties: whoever ran or submitted the count may not approve
      # it themselves. Backstop for direct service calls (the policy hides the UI).
      if self_approval?
        @count.errors.add(:base, Approvals::SelfApproval.error_message)
        return failure
      end

      # Belt-and-suspenders against a duplicate: a count may only ever own one
      # adjustment. (The state machine already prevents re-approval — an approved
      # count can't be reopened — but never create a second adjustment regardless.)
      if @count.stock_adjustment_id.present?
        @count.errors.add(:base, :already_approved)
        return failure
      end

      ActiveRecord::Base.transaction do
        refresh_differences!

        # Only counted rows with a real variance generate an adjustment line.
        # Uncounted (blank) rows are left untouched — never treated as a zero
        # count, so they cannot affect stock.
        diff_items = @count.counted_items.select { |item| item.difference.to_d.nonzero? }
        if diff_items.any?
          adjustment = build_adjustment(diff_items)
          result = AdjustmentPoster.new(adjustment).call
          unless result.ok?
            copy_adjustment_errors(result.adjustment)
            raise ActiveRecord::Rollback
          end
          @count.stock_adjustment = adjustment
        end

        @count.update!(status: :approved, approved_at: Time.current, approved_by: @user)
        return Result.new(ok: true, count: @count)
      end

      failure
    end

    private

    def self_approval?
      Approvals::SelfApproval.by_requester?(approver: @user, requester: @count.completed_by_id) ||
        Approvals::SelfApproval.by_requester?(approver: @user, requester: @count.created_by_id)
    end

    # Refresh system quantity (and the derived variance) for COUNTED rows only;
    # blank rows are deliberately not touched.
    def refresh_differences!
      @count.counted_items.each do |item|
        system_qty = item.product.stock_in(@count.warehouse)
        item.update!(system_quantity: system_qty)   # difference recomputed by callback
      end
    end

    def build_adjustment(diff_items)
      adjustment = @count.business.stock_adjustments.build(
        warehouse:   @count.warehouse,
        adjusted_on: @count.counted_on,
        reason:      :stock_count,
        created_by:  @user,
        notes:       I18n.t("inventory.stock_counts.adjustment_note", number: @count.count_number)
      )
      diff_items.each do |item|
        adjustment.items.build(product: item.product, quantity_difference: item.difference)
      end
      adjustment
    end

    def copy_adjustment_errors(adjustment)
      adjustment.errors.full_messages.each { |msg| @count.errors.add(:base, msg) }
    end

    def failure
      Result.new(ok: false, count: @count)
    end
  end
end
