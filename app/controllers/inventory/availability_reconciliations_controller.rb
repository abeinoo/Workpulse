# Read-only reconciliation report for product availability per warehouse
# (Phase 2). Shows; never applies — Inventory::Reports::AvailabilityReconciliation
# writes nothing.
class Inventory::AvailabilityReconciliationsController < Inventory::BaseController
  def show
    authorize ProductWarehouseSetting, :reconciliation?
    @report = Inventory::Reports::AvailabilityReconciliation.new(current_user.business,
                                                                 warehouse_ids: accessible_warehouse_ids)
  end
end
