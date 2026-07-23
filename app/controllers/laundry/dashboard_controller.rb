# Laundry Operations overview — transfer-driven (dirty waiting, in laundry,
# clean available, in transit, received/dispatched today, damaged/disposed,
# unresolved discrepancies). Every figure is derived from the ledger/transfer
# tables directly — no new cached counters, matching
# Finance::DashboardController's convention.
#
# Batch-derived widgets (washed today, material cost, recent batches) are
# intentionally omitted — LaundryBatch is preserved for a future advanced
# phase but isn't part of the normal operational workflow.
class Laundry::DashboardController < Laundry::BaseController
  def index
    @towel_type = current_user.business.towel_types.active.first
    @laundry_branch = current_user.business.branches.branch_type_laundry.first

    if @towel_type && @laundry_branch
      balances = Laundry::TowelBalances.new(@towel_type)
      @by_status = balances.by_status_for_branch(@laundry_branch)
      @in_transit = balances.in_transit
    else
      @by_status = {}
      @in_transit = 0
    end

    today = Time.current.beginning_of_day..Time.current.end_of_day
    transfers = policy_scope(TowelTransfer)

    @received_today    = transfers.where(received_at: today).count
    @dispatched_today  = transfers.where(dispatched_at: today).count
    @unresolved_count  = transfers.unresolved_discrepancy.count
    @unresolved_recent = transfers.unresolved_discrepancy.order(received_at: :desc).limit(8)
                                  .includes(:source_branch, :destination_branch, items: :towel_type)
  end
end
