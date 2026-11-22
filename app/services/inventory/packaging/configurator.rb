module Inventory
  module Packaging
    # The single application path for a product's packaging chain and, while
    # the product has packaging, its Amount (products.measure_amount)
    # (docs/inventory/multi_unit_nested_packaging_design.md §4.3 – 4.5; Decisions 1, 3, 14).
    #
    # Input: the desired chain, innermost first —
    #   [{ package_unit: "box", contains_quantity: 10 }, { package_unit: "carton", contains_quantity: 12 }]
    # (level 1 contains base units; every higher level a whole number of the
    # level below). Levels the chain keeps unchanged stay as they are; from the
    # first difference on, existing levels are retired (only when no warehouse
    # holds a free package of them and no open document line uses them) and
    # the new ones created. Configuring packaging never changes stock: stock
    # stays loose until a stocktake counts it in packages.
    #
    # Product row locked; one transaction; the database trigger checks the
    # final state before the transaction ends (SET CONSTRAINTS ... IMMEDIATE),
    # so a violation is a failed Result, never an error at an outer commit.
    class Configurator
      include AuditLoggable

      Result = Struct.new(:ok, :product, :error, keyword_init: true) do
        def ok? = ok
      end

      LevelSpec = Data.define(:package_unit, :contains_quantity)
      DEFERRED_TRIGGERS = "product_packaging_levels_check_structure, products_check_packaging_structure".freeze

      def initialize(product_id:, actor:, levels:)
        @product_id = product_id
        @actor      = actor
        @specs      = normalize(levels)
      end

      def call
        ActiveRecord::Base.transaction do
          # The structure triggers are deferred to this transaction's final state;
          # restore that even if an earlier step of an enclosing transaction made
          # them immediate (a second configuration in one transaction).
          ActiveRecord::Base.connection.execute("SET CONSTRAINTS #{DEFERRED_TRIGGERS} DEFERRED")
          @product = Product.where(business_id: @actor.business_id).lock.find(@product_id)
          before   = describe(@product.active_packaging_levels.to_a)
          validate_specs!
          apply!
          @product.reload
          # Check now (a violation becomes a failed Result here, not an error at an
          # outer commit), then leave the triggers deferred for the rest of the
          # transaction, as it was.
          ActiveRecord::Base.connection.execute("SET CONSTRAINTS #{DEFERRED_TRIGGERS} IMMEDIATE")
          ActiveRecord::Base.connection.execute("SET CONSTRAINTS #{DEFERRED_TRIGGERS} DEFERRED")
          after = describe(@product.active_packaging_levels.to_a)
          if before != after
            log_audit!(actor: @actor, auditable: @product, action: "packaging_configured",
                       changes: { packaging: [ before, after ], measure_amount: [ @measure_before&.to_s, @product.measure_amount&.to_s ] },
                       metadata: { product_sku: @product.sku, unit_of_measure: @product.unit_of_measure })
          end
          Result.new(ok: true, product: @product)
        end
      rescue Invalid => e
        Result.new(ok: false, product: @product, error: e.message)
      rescue ActiveRecord::StatementInvalid => e
        raise unless e.cause.is_a?(PG::CheckViolation)

        Result.new(ok: false, product: @product, error: I18n.t("inventory.packaging.errors.structure_invalid"))
      rescue AuditLoggable::AuditWriteFailed
        Result.new(ok: false, product: @product, error: I18n.t("inventory.packaging.errors.audit_failed"))
      end

      class Invalid < StandardError; end

      private

      def normalize(levels)
        Array(levels).map { |l| l.respond_to?(:to_unsafe_h) ? l.to_unsafe_h : l.to_h }
                     .map(&:with_indifferent_access)
                     .reject { |l| l[:package_unit].blank? && l[:contains_quantity].blank? }
                     .map { |l| LevelSpec.new(package_unit: l[:package_unit].to_s, contains_quantity: decimal(l[:contains_quantity])) }
      end

      def decimal(value)
        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def validate_specs!
        fail!(:too_many_levels, max: ProductPackagingLevel::MAX_LEVELS) if @specs.size > ProductPackagingLevel::MAX_LEVELS
        units = @specs.map(&:package_unit)
        fail!(:duplicate_unit) if units.uniq.size != units.size
        @specs.each_with_index do |spec, index|
          fail!(:unknown_unit) unless ProductPackagingLevel::PACKAGE_UNITS.include?(spec.package_unit)
          quantity = spec.contains_quantity
          fail!(:contains_positive, unit: unit_name(spec.package_unit)) if quantity.nil? || !quantity.positive?
          fail!(:contains_precision, unit: unit_name(spec.package_unit)) if quantity.round(3) != quantity
          whole = index.positive? || @product.unit_of_measure == "pieces"
          fail!(:contains_whole, unit: unit_name(spec.package_unit)) if whole && quantity != quantity.truncate
          fail!(:contains_more_than_one, unit: unit_name(spec.package_unit)) if index.positive? && quantity < 2
        end
      end

      def apply!
        existing = @product.active_packaging_levels.to_a
        keep = 0
        keep += 1 while keep < existing.size && keep < @specs.size && same?(existing[keep], @specs[keep])
        retiring = existing.drop(keep)
        retiring.each { |level| ensure_retirable!(level) }
        now = Time.current
        retiring.each do |level|
          level.update_columns(status: "retired", retired_at: now, retired_by_id: @actor.id, updated_at: now)
        end

        base = keep.zero? ? 1.to_d : existing[keep - 1].base_quantity.to_d
        @specs.drop(keep).each_with_index do |spec, offset|
          position = keep + offset + 1
          base *= spec.contains_quantity
          @product.packaging_levels.create!(business_id: @product.business_id, position: position,
                                            package_unit: spec.package_unit, contains_quantity: spec.contains_quantity,
                                            base_quantity: base, created_by: @actor)
        end

        @measure_before = @product.measure_amount
        inner = @specs.first&.contains_quantity
        return if inner.nil? || @product.measure_amount == inner

        @product.configuring_packaging = true
        @product.update!(measure_amount: inner)
      end

      def same?(level, spec)
        level.package_unit == spec.package_unit && level.contains_quantity.to_d == spec.contains_quantity
      end

      # A level still holding free packages somewhere, or named by an open
      # document line, cannot be retired: re-count the stock by Stocktake first
      # (Decision 4) or finish / cancel the document.
      def ensure_retirable!(level)
        held = InventoryPackagingEntry.where(packaging_level_id: level.id).group(:warehouse_id).having("SUM(package_delta) <> 0").count
        fail!(:level_in_stock, unit: unit_name(level.package_unit)) if held.any?
        fail!(:level_on_open_document, unit: unit_name(level.package_unit)) if open_document_lines?(level)
      end

      def open_document_lines?(level)
        StockIssueItem.joins(:stock_issue).where(packaging_level_id: level.id)
                      .merge(StockIssue.where(status: StockIssue::EDITABLE_STATUSES, voided_at: nil)).exists? ||
          GoodsReceiptItem.joins(:goods_receipt).where(packaging_level_id: level.id)
                          .merge(GoodsReceipt.where(status: "draft", voided_at: nil)).exists? ||
          PurchaseRequestItem.joins(:purchase_request).where(packaging_level_id: level.id)
                             .merge(PurchaseRequest.where(status: PurchaseRequest::NEEDS_ACTION_STATUSES)).exists?
      end

      def describe(levels)
        levels.sort_by(&:position).map { |l| "#{l.position}:#{l.package_unit}=#{Inventory::QuantityFormat.plain(l.contains_quantity)}" }.join(" > ")
      end

      def unit_name(code) = I18n.t("inventory.packaging.units.#{code}.one")

      def fail!(key, **args)
        raise Invalid, I18n.t("inventory.packaging.errors.#{key}", **args)
      end
    end
  end
end
