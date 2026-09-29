# Inventory Settings → "ربط المخازن بالفروع": which warehouse supplies each
# branch. Configuration for branch-level reporting only — stock stays owned by
# the warehouse. Viewing follows warehouse visibility; changing needs
# manage_inventory and access to both the new and the current warehouse.
class Inventory::WarehouseSuppliesController < Inventory::BaseController
  Row = Struct.new(:branch, :supply, :inferred_warehouses, keyword_init: true) do
    def explicit_active? = supply&.active?
    def status
      return :explicit if explicit_active?
      return :inactive if supply
      inferred_warehouses.any? ? :inferred : :unlinked
    end
  end

  def index
    raise Pundit::NotAuthorizedError unless policy(WarehouseBranchSupply).index?

    business  = current_user.business
    map       = Inventory::BranchSupplyMap.new(business, warehouse_ids: accessible_warehouse_ids)
    supplies  = policy_scope(WarehouseBranchSupply).includes(:warehouse, :updated_by).index_by(&:branch_id)
    warehouses = business.warehouses.index_by(&:id)
    scoped    = !accessible_warehouse_ids.nil?

    @rows = business.branches.where(active: true).order(:name).filter_map do |branch|
      inferred = map.links_for_branch(branch.id).select(&:inferred?).map { |l| warehouses[l.warehouse_id] }.compact
      supply   = supplies[branch.id]
      # A warehouse-scoped user only sees links involving their warehouses.
      next if scoped && supply.nil? && inferred.empty?

      Row.new(branch: branch, supply: supply, inferred_warehouses: inferred)
    end
    @warehouses = accessible_warehouses
    @can_manage = policy(WarehouseBranchSupply).manage?
  end

  def update
    branch    = current_user.business.branches.find(params[:id])
    warehouse = current_user.business.warehouses.find(params.require(:warehouse_id))
    current   = WarehouseBranchSupply.find_by(branch_id: branch.id)&.warehouse
    raise Pundit::NotAuthorizedError unless policy(WarehouseBranchSupply).assign?(warehouse, current)

    result = Inventory::WarehouseSupplyAssigner.new(branch_id: branch.id, warehouse_id: warehouse.id,
                                                    active: params[:active], actor: current_user).call
    if result.ok?
      redirect_to inventory_warehouse_supplies_path, notice: t("inventory.warehouse_supplies.saved", branch: branch.name)
    else
      redirect_to inventory_warehouse_supplies_path, alert: result.error
    end
  end
end
