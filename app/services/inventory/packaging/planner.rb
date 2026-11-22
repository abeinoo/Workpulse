module Inventory
  module Packaging
    # Pure packaging planner (docs/inventory/multi_unit_nested_packaging_design.md §6): no database.
    # Works on a Balance copy, records the entries an operation needs as steps
    # and refuses what is impossible. Total stock changes only by the quantity
    # moved; opening a package (breakdown) is base-neutral and carries no money.
    #
    #   take_packages(p, n)  strict: n full packages of level p — may open
    #                        higher levels, never uses loose content or lower
    #                        levels; the outermost level only from free packages
    #   take_base(q)         loose content first, then the minimum number of
    #                        packages opened, smallest level first
    #   remove_inflow(p, n)  void of an inflow: packages still free leave as
    #                        packages, the rest leaves as base quantity
    class Planner
      class Refusal < StandardError
        attr_reader :code, :details

        def initialize(code, **details)
          @code    = code
          @details = details
          super("#{code}: #{details}")
        end
      end

      Step = Data.define(:kind, :position, :delta)

      attr_reader :balance, :steps

      def initialize(balance)
        @balance = balance.dup_state
        @steps   = []
      end

      def structure = balance.structure

      def take_packages(position, count)
        count = whole!(count)
        level = level!(position)
        refuse!(:insufficient_stock, needed: count * level.base_quantity) if count * level.base_quantity > balance.total
        begin
          ensure_free(position, count)
        rescue Refusal => e
          raise unless e.code == :insufficient_packages

          # Name what was asked for (3 boxes), not the larger level it tried to open.
          refuse!(:insufficient_packages, position: position, package_unit: level.package_unit,
                                          needed: count, available: balance.free[position])
        end
        balance.free[position] -= count
        balance.total -= count * level.base_quantity
        record(:moved, position, -count)
        self
      end

      def take_base(quantity)
        quantity = quantity.to_d
        return self unless quantity.positive?

        refuse!(:insufficient_stock, needed: quantity) if quantity > balance.total
        if structure.packaged? && balance.loose < quantity
          inner = structure.at(1)
          opened = ((quantity - balance.loose) / inner.base_quantity).ceil
          ensure_free(1, opened)
          balance.free[1] -= opened
          record(:breakdown, 1, -opened)
        end
        balance.total -= quantity
        self
      end

      def add_packages(position, count)
        count = whole!(count)
        level = level!(position)
        balance.free[position] += count
        balance.total += count * level.base_quantity
        record(:moved, position, count)
        self
      end

      def add_base(quantity)
        balance.total += quantity.to_d
        self
      end

      def remove_inflow(position, count)
        count = whole!(count)
        level = level!(position)
        still_free = [ [ balance.free[position], count ].min, 0 ].max
        take_packages(position, still_free) if still_free.positive?
        take_base((count - still_free) * level.base_quantity)
        self
      end

      # A stocktake packaging difference: the counted packages replace the
      # recorded ones; base quantity is moved separately by the count's movement.
      def correct(position, delta)
        delta = whole!(delta, allow_negative: true)
        return self if delta.zero?

        level!(position)
        balance.free[position] += delta
        record(:count_correction, position, delta)
        self
      end

      # Base quantity moved without any packaging decision — a stocktake line
      # whose counted packages are applied separately by #correct (the count
      # states the exact packaging, so nothing is opened). check! refuses a
      # result with negative loose content.
      def adjust_total(delta)
        balance.total += delta.to_d
        self
      end

      # Reverse a recorded entry exactly (a void's moved entries of an outflow,
      # a count reopen's corrections). Quantity is moved by the reversal movement.
      def negate(kind, position, delta)
        level!(position)
        balance.free[position] -= delta
        record(kind, position, -delta)
        self
      end

      def check!
        balance.free.each do |position, count|
          refuse!(:negative_packages, position: position, package_unit: structure.at(position).package_unit) if count.negative?
        end
        refuse!(:negative_loose, loose: balance.loose) if balance.loose.negative?
        self
      end

      private

      # Makes at least `count` free packages of level p by opening higher levels.
      def ensure_free(position, count)
        return if balance.free[position] >= count

        upper = structure.at(position + 1)
        refuse!(:insufficient_packages, position: position, package_unit: structure.at(position).package_unit,
                                        needed: count, available: balance.free[position]) if upper.nil?

        opened = ((count - balance.free[position]).to_d / upper.contains).ceil
        ensure_free(position + 1, opened)
        balance.free[position + 1] -= opened
        balance.free[position] += (opened * upper.contains).to_i
        record(:breakdown, position + 1, -opened)
        record(:breakdown, position, (opened * upper.contains).to_i)
      end

      def level!(position)
        structure.at(position) || refuse!(:unknown_level, position: position)
      end

      def whole!(count, allow_negative: false)
        value = count.to_d
        refuse!(:not_whole_packages, count: value) unless value == value.truncate
        refuse!(:not_whole_packages, count: value) if value.negative? && !allow_negative
        value.to_i
      end

      def record(kind, position, delta)
        @steps << Step.new(kind: kind, position: position, delta: delta) unless delta.zero?
      end

      def refuse!(code, **details)
        raise Refusal.new(code, **details)
      end
    end
  end
end
