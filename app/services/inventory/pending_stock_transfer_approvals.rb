module Inventory
  # The transfers waiting for THIS user's decision — the backend of the
  # inventory workspace's "Pending Approval" badge (no notification records
  # are written; notifications are deferred).
  #
  # Counted only when the user may approve (approve_stock_transfers; legacy
  # broad permissions never count) and only transfers of their business whose
  # BOTH warehouses they reach — exactly what Inventory::StockTransferApproval
  # would let them approve — so a count never reveals another branch's or
  # warehouse's activity.
  class PendingStockTransferApprovals
    def self.for(user) = new(user)

    def initialize(user)
      @user = user
    end

    def relation
      return StockTransfer.none unless @user && StockTransferAuthorization.permits?(@user, :approve)

      scope = StockTransfer.where(business_id: @user.business_id).pending_approval.active
      ids = @user.inventory_warehouse_ids
      ids.nil? ? scope : scope.where(source_warehouse_id: ids, destination_warehouse_id: ids)
    end

    def count = relation.count
  end
end
