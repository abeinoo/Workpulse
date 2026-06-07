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
  class DocumentVoider
    Result = Struct.new(:ok, :document, keyword_init: true) do
      def ok? = ok
    end

    def initialize(document, user:, reason:)
      @document = document
      @user     = user
      @reason   = reason.to_s.strip
    end

    def call
      if @document.voided?
        @document.errors.add(:base, :already_voided)
        return failure
      end

      if @reason.blank?
        @document.errors.add(:void_reason, :blank)
        return failure
      end

      shortfalls = availability_errors
      if shortfalls.any?
        shortfalls.each { |attrs| @document.errors.add(:base, :void_would_oversell, **attrs) }
        return failure
      end

      ActiveRecord::Base.transaction do
        @document.reversal_entries.each do |entry|
          @document.inventory_movements.create!(
            entry.merge(business: @document.business, reason: :reversal, occurred_on: Date.current)
          )
        end

        @document.update!(voided_at: Time.current, voided_by: @user, void_reason: @reason)

        @document.affected_products.each { |product| ProductCostRecalculator.new(product).recompute! }
      end

      Result.new(ok: true, document: @document)
    end

    private

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

    def failure
      Result.new(ok: false, document: @document)
    end
  end
end
