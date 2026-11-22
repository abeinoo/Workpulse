module Inventory
  module Packaging
    # Readable packaging quantities, the one convention for screens, messages
    # and audit text: "1 carton · 2 boxes · 5 pcs (145 pcs)", "3 boxes (30 pcs)".
    module Format
      module_function

      # "1 box", "3 boxes", "0.5 carton" — any amount, formatted exactly.
      def packages(package_unit, count)
        # Singular up to one package ("1 box", "0.5 carton" — the purchasing
        # wording of the approved examples), plural otherwise ("0 boxes", "3 boxes").
        amount = count.to_d
        form = amount.positive? && amount <= 1 ? "one" : "other"
        I18n.t("inventory.packaging.units.#{package_unit}.#{form}", count: Inventory::QuantityFormat.plain(count),
               default: "#{Inventory::QuantityFormat.plain(count)} #{package_unit}")
      end

      # A remaining (or ordered / received) purchase quantity in the purchase
      # unit (Decisions 7, 15): base ÷ the unit's base quantity, truncated
      # toward zero to at most 3 dp — never more than is really left.
      def in_purchase_unit(base_quantity, level)
        (base_quantity.to_d / level.base_quantity.to_d).truncate(3)
      end

      def base(quantity, product)
        "#{Inventory::QuantityFormat.plain(quantity)} #{measure_short(product)}"
      end

      def measure_short(product)
        code = product.respond_to?(:unit_of_measure) ? product.unit_of_measure : product
        I18n.t("inventory.measures.#{code.presence || Product::DEFAULT_UNIT_OF_MEASURE}.short")
      end

      # A document line: "3 boxes (30 pcs)" for a package line, "30 pcs" for a
      # base line.
      def line(product, quantity:, entered_quantity: nil, level: nil)
        return base(quantity, product) if level.nil?

        "#{packages(level.package_unit, entered_quantity || (quantity.to_d / level.base_quantity))} (#{base(quantity, product)})"
      end

      # A balance, outermost first; levels with no free package are left out.
      def balance(product, balance, with_total: true)
        parts = balance.structure.levels.reverse.filter_map do |level|
          count = balance.free[level.position]
          packages(level.package_unit, count) if count.positive?
        end
        loose = balance.loose
        parts << base(loose, product) if loose.positive? || parts.empty?
        text = parts.join(" · ")
        with_total && balance.free.values.any?(&:positive?) ? "#{text} (#{base(balance.total, product)})" : text
      end

      # What a set of steps does, in words: "opens 1 carton · takes 3 sealed boxes".
      # step_data: [[kind, package_unit, delta], …] (planner steps or recorded entries).
      def steps(step_data)
        step_data.filter_map do |kind, package_unit, delta|
          count = delta.to_i.abs
          key = case kind.to_s
          when "breakdown"        then delta.negative? ? "opened" : nil
          when "moved"            then delta.negative? ? "taken" : "added"
          when "count_correction" then delta.negative? ? "counted_out" : "counted_in"
          end
          I18n.t("inventory.packaging.steps.#{key}", packages: packages(package_unit, count)) if key
        end.join(" · ").presence
      end

      def refusal(refusal, product:, balance:)
        details   = refusal.details
        available = balance ? balance(product, balance) : base(0, product)
        case refusal.code
        when :insufficient_packages
          I18n.t("inventory.packaging.refusals.insufficient_packages", product: product.name, sku: product.sku,
                 needed: packages(details[:package_unit], details[:needed]), available: available)
        when :insufficient_stock
          I18n.t("inventory.packaging.refusals.insufficient_stock", product: product.name, sku: product.sku,
                 needed: base(details[:needed], product), available: available)
        when :not_whole_packages
          I18n.t("inventory.packaging.refusals.not_whole_packages", product: product.name)
        else
          I18n.t("inventory.packaging.refusals.packaging_changed", product: product.name, sku: product.sku, available: available)
        end
      end
    end
  end
end
