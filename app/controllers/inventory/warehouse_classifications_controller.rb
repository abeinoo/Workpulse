# Classifies an existing unclassified warehouse (kind NULL) as central or as
# the branch warehouse of an active sales branch. All rules, locks and the
# audit entry live in Inventory::WarehouseManager#classify; this controller
# only authorizes, calls it and renders.
class Inventory::WarehouseClassificationsController < Inventory::BaseController
  before_action :set_warehouse

  def new
    return redirect_already_classified unless @warehouse.kind.nil?

    @branches = manager.classifiable_branches
  end

  def create
    result = manager.classify(warehouse_id: @warehouse.id, kind: classification_params[:kind],
                              branch_id: classification_params[:branch_id].presence,
                              reason: classification_params[:reason])
    if result.ok?
      redirect_to inventory_warehouses_path,
                  notice: t("inventory.warehouses.classification.classified",
                            name: result.warehouse.name,
                            kind: t("inventory.warehouses.kinds.#{result.warehouse.kind}"))
    elsif result.code == :already_classified
      redirect_already_classified
    else
      @error    = result.error
      @branches = manager.classifiable_branches
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_warehouse
    @warehouse = policy_scope(Warehouse).find(params[:warehouse_id])
    authorize @warehouse, :classify?
  end

  def manager = Inventory::WarehouseManager.new(actor: current_user)

  def classification_params
    params.fetch(:classification, {}).permit(:kind, :branch_id, :reason)
  end

  def redirect_already_classified
    redirect_to inventory_warehouses_path, alert: t("inventory.warehouses.errors.already_classified")
  end
end
