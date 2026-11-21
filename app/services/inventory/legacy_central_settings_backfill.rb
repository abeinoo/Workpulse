module Inventory
  # The legacy -> warehouse transition (owner decision 2026-11-20): each
  # product's legacy product-wide values become its CENTRAL warehouse's own
  # availability settings, after which the warehouse alert is the only one:
  #
  #   products.low_stock_level   -> central row low_stock_level   (exact, zeros kept)
  #   products.reorder_quantity  -> central row reorder_quantity  (exact, zeros kept)
  #
  # products.reorder_level (the legacy TOTAL-stock alert level) is never
  # copied anywhere; legacy columns are never changed; branch warehouses are
  # never written.
  #
  # Alert hand-over, per product, with no gap: LowStockQuery evaluates the
  # legacy total alert only while the product's central warehouse has no row
  # of its own (branch rows do not end it). The
  # central row is created (and verified) in one transaction, so the legacy
  # alert works exactly as today until that commit and the central warehouse
  # alert is authoritative from that commit on. A failed or interrupted
  # transfer rolls back: the product keeps its legacy alert. No marker is kept.
  # A transferred threshold of 0 means no central low-stock alert (owner rule);
  # Row#alert_change states that before anything is applied.
  #
  # Two operations: #dry_run (read-only preview) and #apply! (writes; only
  # with explicit approval per environment, through
  # `bin/rails inventory:legacy_central_settings_transfer`).
  #
  # Central warehouse: the business's ONE active warehouse of kind "central",
  # found by query (never by id — ids differ between environments). None or
  # several: every listed product is "unresolved_central" (several = ambiguous:
  # a decision is needed).
  #
  # Listed products (non-parent): those with legacy values (low_stock_level > 0
  # or reorder_quantity > 0), plus those with none that still rely on the
  # legacy total alert. First matching rule wins:
  #   no single active central warehouse   unresolved_central   exception, legacy alert kept
  #   Inactive central row                 inactive_conflict    exception, never reactivated or overwritten
  #   Active central row, same values      matching             transferred / already configured
  #   Active central row, other values     differing            exception, explicit row kept
  #   archived product                     archived             exception, not transferred (decision 3)
  #   untracked product                    untracked            exception, not transferred (decision 3)
  #   no legacy values, relies on the      legacy_alert_only    exception: nothing to transfer, its legacy
  #   legacy total alert                                        (out-of-stock) alert kept until reviewed
  #   otherwise                            to_create            pending transfer
  #
  # apply! re-classifies under the central warehouse's row lock, refuses unless
  # the caller's expectations (central warehouse id + number to create, both from
  # THIS environment's preview) still hold, writes every row through
  # ProductAvailabilityManager#add_many (authorized, one audit entry per row with
  # the actor, source "legacy_central_backfill"), then verifies every created row
  # against the legacy values — all in one transaction (savepoint). All or
  # nothing; a re-run creates only what is still missing.
  class LegacyCentralSettingsBackfill
    Row = Struct.new(:product, :setting, :category, :relies_on_total_alert, keyword_init: true) do
      # The exact values the central row receives.
      def destination
        { low_stock_level: product.low_stock_level, reorder_quantity: product.reorder_quantity,
          receive_low_stock_notification: product.receive_low_stock_notification }
      end

      # What a to_create transfer does to this product's alerts:
      #   before: :total_level (total stock <= reorder_level), :out_of_stock
      #           (total stock <= 0; reorder_level 0) or :none (alerts off)
      #   after:  :central (central stock <= the threshold) or :none (threshold 0,
      #           or alerts off)
      def alert_change
        before = if !relies_on_total_alert then :none
        elsif product.reorder_level.to_i.positive? then :total_level
        else :out_of_stock
        end
        after = product.receive_low_stock_notification? && product.low_stock_level.to_d.positive? ? :central : :none
        { before: before, after: after }
      end

      # The transfer leaves this product without any low-stock alert.
      def loses_alert? = category == "to_create" && alert_change[:before] != :none && alert_change[:after] == :none
    end

    Report = Struct.new(:business, :central, :central_candidates, :rows, :applied, :error, :created, keyword_init: true) do
      def unresolved? = central.nil?
      def ambiguous?  = central_candidates.size > 1
      def by_category = rows.group_by(&:category).transform_values(&:size)
      def of(category) = rows.select { |row| row.category == category }
      def to_create_count = of("to_create").size
      def exceptions = rows.select { |row| EXCEPTIONS.include?(row.category) }
    end

    CATEGORIES = %w[to_create matching differing inactive_conflict archived untracked legacy_alert_only unresolved_central].freeze
    EXCEPTIONS = %w[differing inactive_conflict archived untracked legacy_alert_only unresolved_central].freeze
    SOURCE = "legacy_central_backfill".freeze

    # Mirrors LowStockQuery's legacy total alert eligibility: no row in any
    # central warehouse (it fires at total stock <= reorder_level, so level 0 =
    # out of stock).
    def self.relies_on_total_alert?(product, has_central_row:)
      product.active? && product.track_inventory? && product.receive_low_stock_notification? && !has_central_row
    end

    def initialize(business, actor: nil)
      @business = business
      @actor    = actor
    end

    # Read-only preview.
    def dry_run = build_report(applied: false)

    # Creates and verifies the to_create rows (all or nothing).
    # expected_central_id and expected_count must come from this environment's
    # own preview; if the data changed since, nothing is written
    # (error :preview_mismatch).
    def apply!(expected_central_id:, expected_count:)
      return dry_run.tap { |r| r.error = :no_actor } if @actor.nil?

      report = nil
      # requires_new: a savepoint, so the rollback undoes every row even when
      # this runs inside an outer transaction.
      ActiveRecord::Base.transaction(requires_new: true) do
        report = build_report(applied: false)
        if report.unresolved?
          report.error = report.ambiguous? ? :ambiguous_central : :no_central
          raise ActiveRecord::Rollback
        end
        Warehouse.lock.find(report.central.id) # serialize with every other availability writer
        report = build_report(applied: false)  # re-classify under the lock
        unless report.central.id == expected_central_id.to_i && report.to_create_count == expected_count.to_i
          report.error = :preview_mismatch
          raise ActiveRecord::Rollback
        end

        planned = report.of("to_create")
        created = []
        if planned.any?
          items = planned.map { |row| row.destination.merge(product_id: row.product.id) }
          result = ProductAvailabilityManager.new(actor: @actor).add_many(warehouse_id: report.central.id, items: items, source: SOURCE)
          unless result.ok? && result.skipped.empty?
            report.error = result.ok? ? :preview_mismatch : result.error
            raise ActiveRecord::Rollback
          end
          created = result.records
          unless verified?(planned, report.central)
            report.error = :verification_failed
            raise ActiveRecord::Rollback
          end
        end
        report = build_report(applied: true)
        report.created = created
      end
      report
    end

    private

    # Every planned product now has exactly one Active central row carrying
    # its exact legacy values.
    def verified?(planned, central)
      rows = ProductWarehouseSetting.where(warehouse_id: central.id, product_id: planned.map { |r| r.product.id }).index_by(&:product_id)
      planned.all? do |row|
        setting = rows[row.product.id]
        setting&.status_active? &&
          setting.low_stock_level.to_d == row.product.low_stock_level.to_d &&
          setting.reorder_quantity.to_d == row.product.reorder_quantity.to_d &&
          setting.receive_low_stock_notification == row.product.receive_low_stock_notification
      end
    end

    def build_report(applied:)
      candidates = @business.warehouses.kind_central.where(status: "active").order(:id).to_a
      central = candidates.one? ? candidates.first : nil
      Report.new(business: @business, central: central, central_candidates: candidates, rows: classify(central),
                 applied: applied, created: [])
    end

    def classify(central)
      no_row = "NOT EXISTS (SELECT 1 FROM product_warehouse_settings s JOIN warehouses w ON w.id = s.warehouse_id " \
               "WHERE s.product_id = products.id AND w.kind = 'central')"
      products = @business.products.non_parent
                          .where("products.low_stock_level > 0 OR products.reorder_quantity > 0 OR " \
                                 "(products.active AND products.track_inventory AND products.receive_low_stock_notification AND #{no_row})")
                          .order(:id).to_a
      ids = products.map(&:id)
      settings = central ? ProductWarehouseSetting.where(warehouse_id: central.id, product_id: ids).index_by(&:product_id) : {}
      with_central_row = ProductWarehouseSetting.joins(:warehouse).where(product_id: ids, warehouses: { kind: "central" })
                                                .distinct.pluck(:product_id).to_set
      products.map do |product|
        setting = settings[product.id]
        relies  = self.class.relies_on_total_alert?(product, has_central_row: with_central_row.include?(product.id))
        category = central ? category_for(product, setting, relies) : "unresolved_central"
        Row.new(product: product, setting: setting, category: category, relies_on_total_alert: relies)
      end
    end

    def category_for(product, setting, relies)
      if setting
        return "inactive_conflict" if setting.status_inactive?

        same = setting.low_stock_level.to_d == product.low_stock_level.to_d &&
               setting.reorder_quantity.to_d == product.reorder_quantity.to_d
        return same ? "matching" : "differing"
      end
      return "archived" unless product.active?
      return "untracked" unless product.track_inventory?
      return "legacy_alert_only" if relies && !product.low_stock_level.to_d.positive? && !product.reorder_quantity.to_d.positive?

      "to_create"
    end
  end
end
