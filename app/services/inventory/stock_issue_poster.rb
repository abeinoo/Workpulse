module Inventory
  # Posts a stock issue: validates that every product has enough on-hand in the
  # issue's warehouse (blocking over-issue), values each line at the product's
  # current average cost, then records an OUT movement per line, and marks the
  # issue "issued". All-or-nothing in one transaction. Idempotent by
  # construction — an already-issued issue is refused outright, so calling this
  # twice (e.g. a double form submission) can never double-post.
  #
  # This is the single place inventory actually moves for a stock issue,
  # called from exactly two entry points: the stock-issue import's "Complete
  # Import" step (draft -> issued directly, bypassing approval by design — see
  # Inventory::Imports::StockIssueImportBatchCompleter) and
  # Inventory::StockIssueConfirmationService (approved -> issued, the manual
  # "Confirm Issue" workflow step). It doesn't care what the prior status was,
  # only that the issue isn't already issued.
  class StockIssuePoster
    Result = Struct.new(:ok, :issue, keyword_init: true) do
      def ok? = ok
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      return Result.new(ok: false, issue: @issue) if @issue.persisted? && @issue.issued?

      value_items
      unless availability_ok?
        return Result.new(ok: false, issue: @issue)
      end

      ActiveRecord::Base.transaction do
        @issue.status = :issued

        raise ActiveRecord::Rollback unless @issue.save

        @issue.items.each { |item| post_item(item) }
        return Result.new(ok: true, issue: @issue)
      end

      Result.new(ok: false, issue: @issue)
    end

    private

    # Issue value = current average cost of each product.
    def value_items
      @issue.items.each do |item|
        next if item.product.nil?
        item.unit_cost = item.product.average_cost_price
      end
    end

    # Sums requested quantity per product (a product may appear on >1 line) and
    # compares against on-hand in the target warehouse.
    def availability_ok?
      ok = true
      requested_by_product = @issue.items.reject(&:marked_for_destruction?)
                                   .group_by(&:product_id)

      requested_by_product.each do |product_id, items|
        product = items.first.product
        next if product.nil?

        requested = items.sum { |i| i.quantity.to_d }
        available = product.stock_in(@issue.warehouse)
        next if requested <= available

        ok = false
        @issue.errors.add(:base, :insufficient_stock,
                          product: product.name,
                          sku:       product.sku,
                          available: available.to_s,
                          requested: requested.to_s)
      end

      ok
    end

    def post_item(item)
      @issue.inventory_movements.create!(
        business:    @issue.business,
        product:     item.product,
        warehouse:   @issue.warehouse,
        branch:      @issue.branch,
        direction:   :out,
        reason:      :stock_issue,
        quantity:    item.quantity,
        unit_cost:   item.unit_cost,
        occurred_on: @issue.issued_on
      )
    end
  end
end
