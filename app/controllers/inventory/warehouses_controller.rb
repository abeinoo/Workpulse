class Inventory::WarehousesController < Inventory::BaseController
  def index
    authorize Warehouse
    base = policy_scope(Warehouse) # business + accessible warehouses — the filter only narrows it
    by_kind = base.group(:kind).count
    @kind_counts = {
      "all"          => by_kind.values.sum,
      "central"      => by_kind["central"].to_i,
      "branch"       => by_kind["branch"].to_i,
      "unclassified" => by_kind[nil].to_i
    }
    @kind_filter = Warehouse::KIND_FILTERS.include?(params[:kind]) ? params[:kind] : nil
    @warehouses  = base.for_kind_filter(@kind_filter).includes(:branch).ordered
  end

  def show
    @warehouse = find_warehouse
    authorize @warehouse
  end

  def new
    @warehouse = current_user.business.warehouses.build(status: "active")
    authorize @warehouse
  end

  # A manually created warehouse is always central: the kind is fixed here and
  # never read from the request (warehouse_params has no kind or branch_id).
  # Branch warehouses come only from branch provisioning.
  def create
    authorize Warehouse, :create?
    result = Inventory::WarehouseManager.new(actor: current_user).create(
      kind: "central",
      name: warehouse_params[:name],
      description: warehouse_params[:description],
      status: warehouse_params[:status].presence || "active"
    )
    if result.ok?
      redirect_to inventory_warehouse_path(result.warehouse), notice: t("inventory.warehouses.created")
    else
      @warehouse = result.warehouse ||
                   current_user.business.warehouses.build(warehouse_params.slice(:name, :description))
      @warehouse.errors.add(:base, result.error) if @warehouse.errors.empty?
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @warehouse = find_warehouse
    authorize @warehouse
  end

  def update
    @warehouse = find_warehouse
    authorize @warehouse
    if @warehouse.update(warehouse_params)
      redirect_to inventory_warehouse_path(@warehouse), notice: t("inventory.warehouses.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @warehouse = find_warehouse
    authorize @warehouse
    if @warehouse.destroy
      redirect_to inventory_warehouses_path, notice: t("inventory.warehouses.destroyed")
    else
      redirect_to inventory_warehouses_path, alert: @warehouse.errors.full_messages.to_sentence
    end
  end

  private

  def find_warehouse
    policy_scope(Warehouse).find(params[:id])
  end

  def warehouse_params
    params.require(:warehouse).permit(:name, :description, :status)
  end
end
