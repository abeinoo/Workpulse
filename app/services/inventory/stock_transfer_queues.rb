module Inventory
  # The transit-workflow work lists of ONE user — the Transfers in Transit /
  # Receiving page and the dashboard's "Needs action" counts use exactly these relations,
  # so a list and its count can never disagree. Each list requires its own
  # permission (legacy broad permissions never count) and its own reach rule,
  # never another business's transfers:
  #
  #   to_dispatch    awaiting_dispatch, SOURCE reachable       dispatch_stock_transfers
  #   to_receive     in_transit,        DESTINATION reachable  receive_stock_transfers
  #   discrepancies  discrepancy,       BOTH reachable         resolve_stock_transfer_discrepancies
  #
  # in_transit_visible: every dispatched transfer still open (in transit or
  # with a discrepancy) the user may see (either end — StockTransferPolicy::Scope),
  # for the read-only overview of goods on the road.
  class StockTransferQueues
    def self.for(user) = new(user)

    def initialize(user)
      @user = user
    end

    def to_dispatch
      return StockTransfer.none unless permits?(:dispatch)

      reach(base.awaiting_dispatch, source: true)
    end

    def to_receive
      return StockTransfer.none unless permits?(:receive)

      reach(base.in_transit, destination: true)
    end

    def discrepancies
      return StockTransfer.none unless permits?(:resolve)

      reach(base.discrepancy, source: true, destination: true)
    end

    def in_transit_visible
      return StockTransfer.none unless permits?(:view)

      scope = base.open_in_transit
      ids = @user.inventory_warehouse_ids
      ids.nil? ? scope : scope.where(source_warehouse_id: ids).or(scope.where(destination_warehouse_id: ids))
    end

    private

    def permits?(operation) = @user && StockTransferAuthorization.permits?(@user, operation)

    def base = StockTransfer.where(business_id: @user.business_id).via_transit.active

    def reach(scope, source: false, destination: false)
      ids = @user.inventory_warehouse_ids
      return scope if ids.nil?

      scope = scope.where(source_warehouse_id: ids) if source
      scope = scope.where(destination_warehouse_id: ids) if destination
      scope
    end
  end
end
