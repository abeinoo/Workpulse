module Inventory
  # The one definition of how much of a product a warehouse can still commit
  # to a stock issue:
  #
  #   available = on-hand (InventoryMovement ledger, see StockLevels)
  #             - reserved (lines of APPROVED, non-voided stock issues)
  #
  # A reservation is derived from data shape, never stored: an approved issue
  # has been allocated stock but hasn't moved it yet. Its lifecycle is
  # therefore exactly the issue's status lifecycle —
  #
  #   draft / pending_approval  -> reserves nothing
  #   approved                  -> reserves its quantities  (StockIssueApproval#approve!)
  #   issued                    -> reservation consumed: the OUT movement now
  #                                carries the quantity    (StockIssuePoster)
  #   cancelled                 -> reservation released    (StockIssueCancellation)
  #
  # Each transition is a single status change under the issue's row lock, so
  # a quantity is never counted as both reserved and deducted, and can never
  # be reserved, consumed or released twice.
  #
  # Every check against an issue excludes that issue's own lines from
  # "reserved" — the same rule at approval (allocate) and at confirmation
  # (consume): the issue may take what isn't committed to any OTHER approved
  # issue.
  #
  # Concurrency: callers that allocate or consume stock take .lock_products!
  # inside their transaction BEFORE reading availability — the same Product
  # row lock (FOR UPDATE, id order) StockTransferPoster already uses — so two
  # competing approvals/confirmations/transfers of the same product serialize
  # and the second reads the first's committed result.
  class StockAvailability
    Line = Struct.new(:product, :requested, :on_hand, :reserved, keyword_init: true) do
      # What could still be issued, never shown below zero (on-hand can fall
      # under existing reservations via a count, adjustment or transfer).
      def available = [ on_hand - reserved, 0 ].max
      def shortfall? = requested > on_hand - reserved
    end

    # Lines currently holding a reservation.
    def self.reserved_items
      StockIssueItem.joins(:stock_issue).merge(StockIssue.approved.active)
    end

    def self.lock_products!(product_ids)
      ids = product_ids.compact.uniq.sort
      Product.where(id: ids).order(:id).lock.load if ids.any?
    end

    # { [warehouse_id, product_id] => on_hand }
    def self.on_hand_by(warehouse_ids:, product_ids:)
      InventoryMovement.where(warehouse_id: warehouse_ids, product_id: product_ids)
                       .group(:warehouse_id, :product_id)
                       .sum(Arel.sql(StockLevels::SIGNED))
    end

    # { [warehouse_id, product_id] => reserved }
    def self.reserved_by(warehouse_ids:, product_ids:, excluding_issue_id: nil)
      scope = reserved_items.where(stock_issues: { warehouse_id: warehouse_ids }, product_id: product_ids)
      scope = scope.where.not(stock_issue_id: excluding_issue_id) if excluding_issue_id
      scope.group("stock_issues.warehouse_id", :product_id).sum(:quantity)
    end

    # One Line per product on the issue (quantities summed across duplicate
    # lines), measured in the issue's warehouse. Two queries regardless of
    # line count.
    def self.lines_for(issue)
      grouped = issue.items.reject(&:marked_for_destruction?).select(&:product_id).group_by(&:product_id)
      return [] if grouped.empty? || issue.warehouse_id.nil?

      warehouse_id = issue.warehouse_id
      on_hand  = on_hand_by(warehouse_ids: warehouse_id, product_ids: grouped.keys)
      reserved = reserved_by(warehouse_ids: warehouse_id, product_ids: grouped.keys, excluding_issue_id: issue.id)

      grouped.map do |product_id, items|
        Line.new(product:   items.first.product,
                 requested: items.sum { |i| i.quantity.to_d },
                 on_hand:   on_hand[[ warehouse_id, product_id ]].to_d,
                 reserved:  reserved[[ warehouse_id, product_id ]].to_d)
      end
    end

    # Adds a :base error per short product to issue.errors; true when nothing
    # is short. Read-only — callers that act on the answer must hold
    # .lock_products! first.
    def self.validate!(issue)
      shortages = lines_for(issue).select(&:shortfall?)
      shortages.each do |line|
        product = line.product
        if line.reserved.positive?
          issue.errors.add(:base, :insufficient_stock_reserved,
                           product: product.name, sku: product.sku,
                           available: format_quantity(line.available), requested: format_quantity(line.requested),
                           reserved: format_quantity(line.reserved), on_hand: format_quantity(line.on_hand))
        else
          issue.errors.add(:base, :insufficient_stock,
                           product: product.name, sku: product.sku,
                           available: format_quantity(line.available), requested: format_quantity(line.requested))
        end
      end
      shortages.empty?
    end

    # Ids of the given issues (pending approval or approved) that could not be
    # approved/confirmed right now. For list pages: expects items preloaded;
    # two queries for the whole set.
    def self.unfulfillable_issue_ids(issues)
      candidates = issues.select { |i| !i.voided? && (i.pending_approval? || i.approved?) }
      return Set.new if candidates.empty?

      warehouse_ids = candidates.map(&:warehouse_id).uniq
      product_ids   = candidates.flat_map { |i| i.items.map(&:product_id) }.uniq
      on_hand  = on_hand_by(warehouse_ids: warehouse_ids, product_ids: product_ids)
      reserved = reserved_by(warehouse_ids: warehouse_ids, product_ids: product_ids)

      candidates.each_with_object(Set.new) do |issue, ids|
        issue.items.group_by(&:product_id).each do |product_id, items|
          key       = [ issue.warehouse_id, product_id ]
          requested = items.sum { |i| i.quantity.to_d }
          # The total includes this issue's own lines once it's approved.
          others    = reserved[key].to_d - (issue.approved? ? requested : 0)
          next if requested <= on_hand[key].to_d - others

          ids << issue.id
          break
        end
      end
    end

    def self.format_quantity(quantity)
      ActiveSupport::NumberHelper.number_to_rounded(quantity.to_d, precision: 3, strip_insignificant_zeros: true)
    end
  end
end
