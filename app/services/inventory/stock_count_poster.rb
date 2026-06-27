module Inventory
  # Posts a draft physical count: refreshes each line's system quantity from live
  # stock, computes the difference (counted − system), and generates ONE
  # stock-count Inventory Adjustment from the non-zero differences — so the ledger
  # is corrected through the normal adjustment path (full audit trail, voidable).
  # The count is then frozen as "posted".
  #
  # Recomputing the system quantity at post time guarantees the warehouse ends at
  # exactly the counted quantity and never produces negative stock (a shortfall
  # can't exceed what's on hand).
  class StockCountPoster
    Result = Struct.new(:ok, :count, keyword_init: true) do
      def ok? = ok
    end

    def initialize(count, user:)
      @count = count
      @user  = user
    end

    def call
      unless @count.draft?
        @count.errors.add(:base, :not_draft)
        return failure
      end

      ActiveRecord::Base.transaction do
        refresh_differences!

        diff_items = @count.items.select { |item| item.difference.to_d.nonzero? }
        if diff_items.any?
          adjustment = build_adjustment(diff_items)
          result = AdjustmentPoster.new(adjustment).call
          unless result.ok?
            copy_adjustment_errors(result.adjustment)
            raise ActiveRecord::Rollback
          end
          @count.stock_adjustment = adjustment
        end

        @count.update!(status: :posted, posted_at: Time.current, posted_by: @user)
        return Result.new(ok: true, count: @count)
      end

      failure
    end

    private

    def refresh_differences!
      @count.items.each do |item|
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
