# The Transfer Approvals queue: the pending transfers the current user may
# approve — read-only. Approving, rejecting and editing stay on the transfer's
# own page (Inventory::StockTransfersController), each through its service.
#
# The list IS Inventory::PendingStockTransferApprovals#relation — the same
# relation the workspace badge counts — so the two can never disagree:
# approve_stock_transfers required (legacy broad permissions never grant it),
# pending_approval only, transfers of the user's business whose BOTH
# warehouses the user reaches.
class Inventory::StockTransferApprovalsController < Inventory::BaseController
  def index
    authorize StockTransfer, :approvals?
    @stock_transfers = Inventory::PendingStockTransferApprovals.for(current_user).relation
                                .includes({ source_warehouse: :branch }, { destination_warehouse: :branch },
                                          :created_by, :submitted_by, :items)
                                .order(:submitted_at, :id)
                                .to_a
    # The badge reads this instead of counting again (WorkspaceHelper).
    @pending_stock_transfer_approvals_count = @stock_transfers.size
  end

  private

  # Approvers need no inventory view to open their queue.
  def admitted_without_inventory_view? = Inventory::StockTransferAuthorization.permits?(current_user, :approve)
end
