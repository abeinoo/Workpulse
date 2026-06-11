class Inventory::WarehousesController < Inventory::BaseController
  def index
    authorize Warehouse
    @warehouses = policy_scope(Warehouse).ordered
  end

  def show
    @warehouse = find_warehouse
    authorize @warehouse
  end

  def new
    @warehouse = current_user.business.warehouses.build(status: "active")
    authorize @warehouse
  end

  def create
    @warehouse = current_user.business.warehouses.build(warehouse_params)
    authorize @warehouse
    if @warehouse.save
      redirect_to inventory_warehouse_path(@warehouse), notice: t("inventory.warehouses.created")
    else
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
