module Inventory
  # The one definition of how much of a product a warehouse can still commit:
  #
  #   available = on-hand (InventoryMovement ledger, see StockLevels)
  #             - reserved by APPROVED, non-voided stock issues
  #             - reserved by PENDING-APPROVAL, non-voided stock transfers
  #                 (in their SOURCE warehouse)
  #
  # A reservation is derived from data shape, never stored: it is the lines of
  # a document whose status holds stock that hasn't moved yet. Its lifecycle
  # is exactly the document's status lifecycle —
  #
  #   Stock issue (unchanged)
  #     draft / pending_approval  -> reserves nothing
  #     approved                  -> reserves   (StockIssueApproval#approve!)
  #     issued                    -> consumed: the OUT movement now carries
  #                                  the quantity  (StockIssuePoster)
  #     cancelled                 -> released   (StockIssueCancellation)
  #
  #   Stock transfer
  #     draft                     -> reserves nothing
  #     pending_approval          -> reserves   (StockTransferSubmission; an
  #                                  approver's edit changes it in place —
  #                                  StockTransferEditor)
  #     approved                  -> consumed: the OUT/IN movements are posted
  #                                  (StockTransferApproval / StockTransferPoster)
  #     rejected / cancelled      -> released   (StockTransferRejection /
  #                                  StockTransferCancellation)
  #
  # Each transition is a single status change under the document's row lock,
  # so a quantity is never counted as both reserved and deducted, and can
  # never be reserved, consumed or released twice.
  #
  # Every check against a document excludes that document's own lines from
  # "reserved" (excluding_issue_id / excluding_transfer_id): the document may
  # take what isn't committed to any OTHER document.
  #
  # Concurrency: callers that allocate or consume stock take .lock_products!
  # inside their transaction BEFORE reading availability (after their own
  # document row lock) — Product rows FOR UPDATE in id order — so two
  # competing approvals/submissions/confirmations/removals of the same product
  # serialize and the second reads the first's committed result.
  class StockAvailability
    # reserved = every reservation by other documents; transfer_reserved = the
    # part of it held by pending transfers.
    Line = Struct.new(:product, :requested, :on_hand, :reserved, :transfer_reserved, keyword_init: true) do
      # What could still be committed, never shown below zero.
      def available = [ on_hand - reserved, 0 ].max
      def shortfall? = requested > on_hand - reserved
      def issue_reserved = reserved - transfer_reserved.to_d
    end

    # Stock issue lines currently holding a reservation.
    def self.reserved_items
      StockIssueItem.joins(:stock_issue).merge(StockIssue.approved.active)
    end

    # Stock transfer lines currently holding a reservation (source warehouse).
    def self.reserved_transfer_items
      StockTransferItem.joins(:stock_transfer).merge(StockTransfer.reserving)
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

    # { [warehouse_id, product_id] => reserved } — issues and transfers together.
    def self.reserved_by(warehouse_ids:, product_ids:, excluding_issue_id: nil, excluding_transfer_id: nil)
      reserved_split(warehouse_ids: warehouse_ids, product_ids: product_ids, excluding_issue_id: excluding_issue_id,
                     excluding_transfer_id: excluding_transfer_id)
        .transform_values { |parts| parts.values.sum }
    end

    # { [warehouse_id, product_id] => { "issue" => qty, "transfer" => qty } } —
    # both kinds of reservation in ONE query (UNION ALL), so adding transfer
    # reservations costs no extra round-trip for any caller.
    def self.reserved_split(warehouse_ids:, product_ids:, excluding_issue_id: nil, excluding_transfer_id: nil)
      issues = reserved_items.where(stock_issues: { warehouse_id: warehouse_ids }, product_id: product_ids)
      issues = issues.where.not(stock_issue_id: excluding_issue_id) if excluding_issue_id
      transfers = reserved_transfer_items.where(stock_transfers: { source_warehouse_id: warehouse_ids }, product_id: product_ids)
      transfers = transfers.where.not(stock_transfer_id: excluding_transfer_id) if excluding_transfer_id

      issue_sql = issues.select("'issue' AS kind, stock_issues.warehouse_id AS warehouse_id, " \
                                "stock_issue_items.product_id AS product_id, stock_issue_items.quantity AS quantity").to_sql
      transfer_sql = transfers.select("'transfer' AS kind, stock_transfers.source_warehouse_id AS warehouse_id, " \
                                      "stock_transfer_items.product_id AS product_id, stock_transfer_items.quantity AS quantity").to_sql
      rows = ActiveRecord::Base.connection.select_rows(<<~SQL.squish, "StockAvailability Reserved")
        SELECT kind, warehouse_id, product_id, SUM(quantity)
        FROM (#{issue_sql} UNION ALL #{transfer_sql}) reservations
        GROUP BY kind, warehouse_id, product_id
      SQL
      rows.each_with_object(Hash.new { |h, k| h[k] = {} }) do |(kind, warehouse_id, product_id, quantity), split|
        split[[ warehouse_id.to_i, product_id.to_i ]][kind] = quantity.to_d
      end
    end

    # One Line per product on the issue (quantities summed across duplicate
    # lines), measured in the issue's warehouse.
    def self.lines_for(issue)
      grouped = issue.items.reject(&:marked_for_destruction?).select(&:product_id).group_by(&:product_id)
      return [] if grouped.empty? || issue.warehouse_id.nil?

      build_lines(warehouse_id: issue.warehouse_id,
                  requested: grouped.transform_values { |items| items.sum { |i| i.quantity.to_d } },
                  products: grouped.transform_values { |items| items.first.product },
                  excluding_issue_id: issue.id)
    end

    # One Line per product on the transfer, measured in its SOURCE warehouse,
    # never competing against the transfer's own reservation.
    def self.transfer_lines_for(transfer)
      grouped = transfer.items.reject(&:marked_for_destruction?).select(&:product_id).group_by(&:product_id)
      return [] if grouped.empty? || transfer.source_warehouse_id.nil?

      build_lines(warehouse_id: transfer.source_warehouse_id,
                  requested: grouped.transform_values { |items| items.sum { |i| i.quantity.to_d } },
                  products: grouped.transform_values { |items| items.first.product },
                  excluding_transfer_id: transfer.id)
    end

    def self.build_lines(warehouse_id:, requested:, products:, excluding_issue_id: nil, excluding_transfer_id: nil)
      ids      = requested.keys
      on_hand  = on_hand_by(warehouse_ids: warehouse_id, product_ids: ids)
      split    = reserved_split(warehouse_ids: warehouse_id, product_ids: ids,
                                excluding_issue_id: excluding_issue_id, excluding_transfer_id: excluding_transfer_id)

      requested.map do |product_id, quantity|
        key   = [ warehouse_id, product_id ]
        parts = split.fetch(key, {})
        held  = parts.fetch("transfer", 0).to_d
        Line.new(product: products[product_id], requested: quantity, on_hand: on_hand[key].to_d,
                 reserved: parts.fetch("issue", 0).to_d + held, transfer_reserved: held)
      end
    end

    # Adds a :base error per short product to issue.errors; true when nothing
    # is short. Read-only — callers that act on the answer must hold
    # .lock_products! first. When only other stock issues hold the stock the
    # message is the one issues always had; when pending transfers hold part
    # of it, the message names the documents.
    def self.validate!(issue)
      shortages = lines_for(issue).select(&:shortfall?)
      holders   = shortage_holders(issue.warehouse_id, shortages.select { |l| l.transfer_reserved.positive? },
                                   excluding_issue_id: issue.id)
      shortages.each do |line|
        product = line.product
        common  = { product: product.name, sku: product.sku, warehouse: issue.warehouse&.name,
                    available: format_quantity(line.available), requested: format_quantity(line.requested) }
        if line.transfer_reserved.positive?
          issue.errors.add(:base, :insufficient_stock_reserved_documents,
                           **common, reserved: format_quantity(line.reserved), on_hand: format_quantity(line.on_hand),
                           documents: holders.fetch(product.id).label)
        elsif line.reserved.positive?
          issue.errors.add(:base, :insufficient_stock_reserved,
                           **common, reserved: format_quantity(line.reserved), on_hand: format_quantity(line.on_hand))
        else
          issue.errors.add(:base, :insufficient_stock, **common)
        end
      end
      shortages.empty?
    end

    # Transfer counterpart of .validate!: every product must be available in
    # the source warehouse after what OTHER documents reserve. Used at
    # submission (reserve), approver edit (re-reserve) and approval (consume).
    # Read-only — callers hold .lock_products! first.
    def self.validate_transfer!(transfer)
      shortages = transfer_lines_for(transfer).select(&:shortfall?)
      holders   = shortage_holders(transfer.source_warehouse_id, shortages.select { |l| l.reserved.positive? },
                                   excluding_transfer_id: transfer.id)
      shortages.each do |line|
        product = line.product
        common  = { product: product.name, sku: product.sku, warehouse: transfer.source_warehouse&.name,
                    available: format_quantity(line.available), requested: format_quantity(line.requested) }
        if line.reserved.positive?
          transfer.errors.add(:base, :insufficient_stock_reserved,
                              **common, reserved: format_quantity(line.reserved), on_hand: format_quantity(line.on_hand),
                              documents: holders.fetch(product.id).label)
        else
          transfer.errors.add(:base, :insufficient_stock, **common)
        end
      end
      shortages.empty?
    end

    # Ids of the given issues (pending approval or approved) that could not be
    # approved/confirmed right now. For list pages: expects items preloaded.
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

    # The documents holding a product's reservation in a warehouse.
    Holders = Struct.new(:issue_numbers, :transfer_numbers, keyword_init: true) do
      def transfers? = transfer_numbers.any?

      def label
        parts = []
        if issue_numbers.any?
          parts << I18n.t("inventory.stock_availability.holders.stock_issues", numbers: issue_numbers.join(", "))
        end
        if transfer_numbers.any?
          parts << I18n.t("inventory.stock_availability.holders.stock_transfers", numbers: transfer_numbers.join(", "))
        end
        parts.join("; ")
      end
    end

    # { product_id => Holders } for the given products (Line or ids).
    def self.holders_by(warehouse_id:, product_ids:, excluding_issue_id: nil, excluding_transfer_id: nil)
      return {} if product_ids.empty?

      issues = reserved_items.where(stock_issues: { warehouse_id: warehouse_id }, product_id: product_ids)
      issues = issues.where.not(stock_issue_id: excluding_issue_id) if excluding_issue_id
      transfers = reserved_transfer_items.where(stock_transfers: { source_warehouse_id: warehouse_id }, product_id: product_ids)
      transfers = transfers.where.not(stock_transfer_id: excluding_transfer_id) if excluding_transfer_id

      issue_numbers    = issues.distinct.pluck(:product_id, "stock_issues.issue_number").group_by(&:first)
      transfer_numbers = transfers.distinct.pluck(:product_id, "stock_transfers.transfer_number").group_by(&:first)
      product_ids.index_with do |product_id|
        Holders.new(issue_numbers: issue_numbers.fetch(product_id, []).map(&:last).sort,
                    transfer_numbers: transfer_numbers.fetch(product_id, []).map(&:last).sort)
      end
    end

    def self.shortage_holders(warehouse_id, lines, **excluding)
      holders_by(warehouse_id: warehouse_id, product_ids: lines.map { |l| l.product.id }, **excluding)
    end

    # Reservation protection for every removal that does not consume its own
    # reservation (adjustments, count approval, voids, laundry, ...):
    #
    #   on_hand − removal >= reserved   (issues AND pending transfers)
    #
    # removals: { product_id => base quantity removed from warehouse_id }.
    # Returns one Shortfall per product that would break the invariant, naming
    # the documents holding the stock. Callers hold .lock_products!.
    Shortfall = Struct.new(:product, :warehouse, :removal, :on_hand, :reserved, :issue_numbers, :transfer_numbers,
                           keyword_init: true) do
      def available = [ on_hand - reserved, 0 ].max
      def holders = Holders.new(issue_numbers: issue_numbers, transfer_numbers: transfer_numbers)
    end

    def self.removal_shortfalls(warehouse:, removals:, excluding_issue_id: nil, excluding_transfer_id: nil)
      removals = removals.transform_values(&:to_d).select { |_, quantity| quantity.positive? }
      return [] if removals.empty?

      excluding = { excluding_issue_id: excluding_issue_id, excluding_transfer_id: excluding_transfer_id }
      on_hand  = on_hand_by(warehouse_ids: warehouse.id, product_ids: removals.keys)
      reserved = reserved_by(warehouse_ids: warehouse.id, product_ids: removals.keys, **excluding)
      short = removals.select do |product_id, quantity|
        held = reserved[[ warehouse.id, product_id ]].to_d
        held.positive? && on_hand[[ warehouse.id, product_id ]].to_d - quantity < held
      end
      return [] if short.empty?

      products = Product.where(id: short.keys).index_by(&:id)
      holders  = holders_by(warehouse_id: warehouse.id, product_ids: short.keys, **excluding)
      short.map do |product_id, quantity|
        Shortfall.new(product: products[product_id], warehouse: warehouse, removal: quantity,
                      on_hand: on_hand[[ warehouse.id, product_id ]].to_d, reserved: reserved[[ warehouse.id, product_id ]].to_d,
                      issue_numbers: holders[product_id].issue_numbers, transfer_numbers: holders[product_id].transfer_numbers)
      end
    end

    # Adds a conflict error per shortfall to record.errors; true when none.
    # Only stock issues holding the stock -> the message removals always had
    # (:reserved_stock_conflict); pending transfers among the holders -> the
    # message naming every holding document.
    def self.protect_reservations!(record, warehouse:, removals:, excluding_issue_id: nil, excluding_transfer_id: nil)
      shortfalls = removal_shortfalls(warehouse: warehouse, removals: removals,
                                      excluding_issue_id: excluding_issue_id, excluding_transfer_id: excluding_transfer_id)
      shortfalls.each do |s|
        common = { product: s.product.name, sku: s.product.sku, warehouse: warehouse.name,
                   removal: format_quantity(s.removal), on_hand: format_quantity(s.on_hand),
                   reserved: format_quantity(s.reserved) }
        if s.transfer_numbers.any?
          record.errors.add(:base, :reserved_stock_conflict_documents, **common, documents: s.holders.label)
        else
          record.errors.add(:base, :reserved_stock_conflict, **common, issues: s.issue_numbers.join(", "))
        end
      end
      shortfalls.empty?
    end

    # Current averages read from the rows locked by .lock_products!, so a
    # line is valued with the average as committed, never a stale instance.
    def self.locked_averages(product_ids)
      ids = product_ids.compact.uniq
      ids.any? ? Product.where(id: ids).pluck(:id, :average_cost_price).to_h : {}
    end

    def self.format_quantity(quantity)
      ActiveSupport::NumberHelper.number_to_rounded(quantity.to_d, precision: 3, strip_insignificant_zeros: true)
    end
  end
end
