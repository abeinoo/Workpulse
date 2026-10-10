module Inventory
  # Posts a stock issue: validates that every product has enough stock
  # available to it in the issue's warehouse — on-hand minus what OTHER
  # approved issues have reserved (see Inventory::StockAvailability) —
  # blocking over-issue, values each line at the product's
  # current average cost, then records an OUT movement per line, and marks the
  # issue "issued". All-or-nothing in one transaction. Idempotent by
  # construction — an already-issued issue is refused outright, so calling this
  # twice (e.g. a double form submission) can never double-post.
  #
  # This is the single place inventory actually moves for a stock issue, and
  # it only ever moves an APPROVED issue: approved -> issued. Its one entry
  # point is Inventory::StockIssueConfirmationService (the "Confirm Issue"
  # workflow step). Every other creation path — manual, CSV/Excel import —
  # goes through draft -> pending_approval -> approved first; an unapproved
  # issue is refused here with a :not_approved error, so no caller can
  # bypass approval. StockIssue's own validation enforces the same rule on
  # any save that sets status to "issued".
  class StockIssuePoster
    Result = Struct.new(:ok, :issue, keyword_init: true) do
      def ok? = ok
    end

    def initialize(issue)
      @issue = issue
    end

    def call
      return Result.new(ok: false, issue: @issue) if @issue.persisted? && @issue.issued?

      unless @issue.approved?
        @issue.errors.add(:base, :not_approved)
        return Result.new(ok: false, issue: @issue)
      end

      ActiveRecord::Base.transaction do
        # Serializes against every other approval/confirmation/transfer of the
        # same products, so the availability read below can't go stale before
        # the OUT movements are written.
        StockAvailability.lock_products!(@issue.items.map(&:product_id))
        value_items
        return Result.new(ok: false, issue: @issue) unless availability_ok?

        # approved -> issued consumes this issue's reservation in the same
        # write that posts its OUT movements: the quantity stops counting as
        # reserved exactly when it starts counting as deducted.
        @issue.status = :issued

        raise ActiveRecord::Rollback unless @issue.save

        @issue.items.each { |item| post_item(item) }
        return Result.new(ok: true, issue: @issue)
      end

      Result.new(ok: false, issue: @issue)
    end

    # Sums requested quantity per product (a product may appear on >1 line) and
    # compares against what's available to this issue in its warehouse,
    # adding an insufficient-stock error per short product. Read-only — also
    # used by the import's "Complete Import" step to flag short rows before
    # submitting for approval (the locked check here at posting time, and at
    # approval, stays authoritative).
    def availability_ok?
      StockAvailability.validate!(@issue)
    end

    private

    # Issue value = current average cost of each product.
    def value_items
      @issue.items.each do |item|
        next if item.product.nil?
        item.unit_cost = item.product.average_cost_price
      end
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
