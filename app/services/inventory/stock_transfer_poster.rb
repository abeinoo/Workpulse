module Inventory
  # Posts a warehouse-to-warehouse transfer: validates that every product has
  # enough on-hand in the SOURCE warehouse, then records a paired OUT (source)
  # and IN (destination) movement per line. Quantity moves between warehouses;
  # the product's average cost is unchanged (same product, same business), so
  # both movements are valued at the current average cost for ledger consistency.
  #
  # Transfers are intentionally immediate — there is no draft/approval stage
  # (no status column, no edit route); creating one IS posting it.
  #
  # All-or-nothing: the transfer row and BOTH movements of every line are
  # written in one transaction, so a failure can never move stock out of the
  # source without moving it into the destination. The product rows are
  # locked before the source-stock check (inside that transaction), so two
  # concurrent transfers/issues can't both pass the check and overdraw it.
  #
  # A product whose availability in the DESTINATION warehouse is Inactive is
  # refused (Inventory::IncomingAvailabilityGuard) — no exception. The source
  # side is never checked: taking stock out of an Inactive pair is allowed.
  #
  # Packaging (docs/inventory/multi_unit_nested_packaging_design.md §7.4): a package line
  # leaves the source as full packages (opening a larger package only when
  # needed) and arrives at the destination as the same sealed packages; a base
  # line leaves loose-first and arrives loose. Base quantity and value are
  # equal on both sides. Reserved stock in the source is protected
  # (on-hand − transfer >= reserved). Posting is audited (BUG-074).
  class StockTransferPoster
    include AuditLoggable

    Result = Struct.new(:ok, :transfer, keyword_init: true) do
      def ok? = ok
    end

    def initialize(transfer)
      @transfer = transfer
    end

    def call
      return Result.new(ok: false, transfer: @transfer) unless valid_warehouses?

      ActiveRecord::Base.transaction do
        lock_products!
        value_items
        raise ActiveRecord::Rollback unless destination_accepts_incoming?
        raise ActiveRecord::Rollback unless availability_ok?
        raise ActiveRecord::Rollback unless reservations_protected?

        @packaging = Packaging::Session.new(business: @transfer.business, product_ids: @transfer.items.map(&:product_id),
                                            warehouse_ids: [ @transfer.source_warehouse_id, @transfer.destination_warehouse_id ])

        @transfer.transfer_number = NumberSequencer.new(@transfer.business, :stock_transfer).next_number if @transfer.transfer_number.blank?

        raise ActiveRecord::Rollback unless @transfer.save

        @transfer.items.each { |item| post_item(item) }
        audit_posting
        return Result.new(ok: true, transfer: @transfer)
      end

      Result.new(ok: false, transfer: @transfer)
    rescue Packaging::Refused => e
      @transfer.errors.add(:base, :packaging_refused, message: e.message)
      Result.new(ok: false, transfer: @transfer)
    end

    private

    # Valued with the average read under the product locks (BUG-071).
    def value_items
      averages = StockAvailability.locked_averages(@transfer.items.map(&:product_id))
      @transfer.items.each do |item|
        next if item.product.nil?
        item.unit_cost = averages.fetch(item.product_id, item.product.average_cost_price)
      end
    end

    def reservations_protected?
      removals = @transfer.items.reject(&:marked_for_destruction?).select(&:product_id)
                          .group_by(&:product_id).transform_values { |items| items.sum { |i| i.quantity.to_d } }
      StockAvailability.protect_reservations!(@transfer, warehouse: @transfer.source_warehouse, removals: removals)
    end

    def audit_posting
      return if @transfer.created_by.nil?

      log_audit(
        actor: @transfer.created_by, auditable: @transfer, action: "post",
        metadata: {
          transfer_number:          @transfer.transfer_number,
          source_warehouse_id:      @transfer.source_warehouse_id,
          destination_warehouse_id: @transfer.destination_warehouse_id,
          lines: @transfer.items.map do |i|
            { product_id: i.product_id, quantity: Inventory::QuantityFormat.plain(i.quantity),
              entered_quantity: i.entered_quantity && Inventory::QuantityFormat.plain(i.entered_quantity),
              packaging_level_id: i.packaging_level_id, unit_cost: i.unit_cost.to_d.to_s("F") }.compact
          end
        }
      )
    end

    # Row locks (FOR UPDATE, id order to avoid deadlocks) serialize posts that
    # touch the same products until this transaction commits.
    def lock_products!
      ids = @transfer.items.map(&:product_id).compact.uniq.sort
      Product.where(id: ids).order(:id).lock.load if ids.any?
    end

    # Runs under the product locks; locks the destination pair rows last.
    def destination_accepts_incoming?
      guard = IncomingAvailabilityGuard.new(
        warehouse_id: @transfer.destination_warehouse_id,
        product_ids:  @transfer.items.reject(&:marked_for_destruction?).map(&:product_id)
      )
      !guard.refuse!(@transfer)
    end

    # Surfaces the "same warehouse" validation early so availability isn't even
    # checked against a nonsensical source == destination — and refuses any
    # warehouse or product of another business before availability reads (and
    # reports) that business's on-hand (IP-1).
    def valid_warehouses?
      @transfer.valid?
      @transfer.errors[:destination_warehouse_id].empty? &&
        @transfer.errors.none? { |error| error.type == :other_business }
    end

    # Sums requested quantity per product and compares against on-hand in the
    # source warehouse, blocking transfers that would overdraw it.
    def availability_ok?
      ok = true
      @transfer.items.reject(&:marked_for_destruction?)
               .group_by(&:product_id).each do |_product_id, items|
        product = items.first.product
        next if product.nil?

        requested = items.sum { |i| i.quantity.to_d }
        available = product.stock_in(@transfer.source_warehouse)
        next if requested <= available

        ok = false
        @transfer.errors.add(:base, :insufficient_stock,
                             product:   product.name,
                             sku:       product.sku,
                             available: available.to_s,
                             requested: requested.to_s)
      end

      ok
    end

    def post_item(item)
      common = {
        business:    @transfer.business,
        product:     item.product,
        quantity:    item.quantity,
        unit_cost:   item.unit_cost,
        occurred_on: @transfer.transferred_on
      }

      out = @transfer.inventory_movements.create!(
        common.merge(warehouse: @transfer.source_warehouse,      direction: :out, reason: :transfer_out)
      )
      @packaging.apply!(product: item.product, warehouse_id: @transfer.source_warehouse_id, source: @transfer,
                        occurred_on: @transfer.transferred_on, movement: out) do |plan|
        item.package_line? ? plan.take_packages(item.packaging_level.position, item.entered_quantity) : plan.take_base(item.quantity)
      end

      inbound = @transfer.inventory_movements.create!(
        common.merge(warehouse: @transfer.destination_warehouse, direction: :in,  reason: :transfer_in)
      )
      @packaging.apply!(product: item.product, warehouse_id: @transfer.destination_warehouse_id, source: @transfer,
                        occurred_on: @transfer.transferred_on, movement: inbound) do |plan|
        item.package_line? ? plan.add_packages(item.packaging_level.position, item.entered_quantity) : plan.add_base(item.quantity)
      end
    end
  end
end
