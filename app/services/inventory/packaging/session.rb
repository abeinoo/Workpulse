module Inventory
  module Packaging
    # Packaging for one posting transaction. The caller has already locked the
    # products (StockAvailability.lock_products!) and writes the inventory
    # movements itself; the session plans each line on the balance as it
    # stands after the previous lines, refuses what is impossible
    # (Planner::Refusal, before anything of that line is written) and writes the
    # packaging entries. Products without packaging levels are untouched: no
    # query beyond the structure lookup, no entry.
    #
    # Balances are read when the session is built: build it after the locks
    # and BEFORE writing any movement of the posting (the session then tracks
    # every line itself).
    class Session
      def initialize(business:, product_ids:, warehouse_ids:)
        @business      = business
        @structures    = Structure.for_products(product_ids)
        @warehouse_ids = Array(warehouse_ids).compact.uniq
        @balances      = Balance.load(structures: @structures, warehouse_ids: @warehouse_ids)
      end

      def structure(product_id) = @structures.fetch(product_id) { @structures[product_id] = Structure.new(product_id, []) }
      def packaged?(product_id) = structure(product_id).packaged?

      def balance(warehouse_id, product_id)
        @balances.fetch([ warehouse_id, product_id ]) do
          raise ArgumentError, "warehouse #{warehouse_id} was not loaded into this packaging session"
        end
      end

      # Plans with a Planner on the current balance, checks the invariants and
      # writes the steps. Returns the steps (empty for unpackaged products).
      # Raises Refused (a readable message) when the plan is impossible.
      def apply!(product:, warehouse_id:, source:, occurred_on:, movement: nil, &block)
        return [] unless packaged?(product.id)

        planner = plan(product, warehouse_id, &block)
        EntryWriter.write!(steps: planner.steps, structure: structure(product.id), business: @business,
                           product_id: product.id, warehouse_id: warehouse_id, source: source,
                           occurred_on: occurred_on, movement: movement)
        @balances[[ warehouse_id, product.id ]] = planner.balance
        planner.steps
      end

      # Read-only plan (approval warnings, previews): never writes. Returns the
      # refusal message, or nil when the plan works.
      def try(product:, warehouse_id:, &block)
        return nil unless packaged?(product.id)

        planner = plan(product, warehouse_id, &block)
        @balances[[ warehouse_id, product.id ]] = planner.balance
        nil
      rescue Refused => e
        e.message
      end

      # Read-only preview for screens: the steps a line would take, or the
      # refusal message. Lines are previewed in order on one running balance.
      Preview = Data.define(:steps, :error)

      def preview(product:, warehouse_id:, &block)
        return Preview.new(steps: [], error: nil) unless packaged?(product.id)

        planner = plan(product, warehouse_id, &block)
        @balances[[ warehouse_id, product.id ]] = planner.balance
        Preview.new(steps: planner.steps, error: nil)
      rescue Refused => e
        Preview.new(steps: [], error: e.message)
      end

      private

      def plan(product, warehouse_id)
        current = balance(warehouse_id, product.id)
        planner = Planner.new(current)
        yield planner
        planner.check!
        planner
      rescue Planner::Refusal => e
        raise Refused, Format.refusal(e, product: product, balance: current)
      end
    end
  end
end
