class Inventory::SuppliersController < Inventory::BaseController
  def index
    authorize Supplier
    @suppliers = policy_scope(Supplier).ordered
  end

  def show
    @supplier = find_supplier
    authorize @supplier
    @recent_receipts = @supplier.goods_receipts.recent.includes(:warehouse).limit(10)
  end

  def new
    @supplier = current_user.business.suppliers.build
    authorize @supplier
  end

  def create
    @supplier = current_user.business.suppliers.build(supplier_params)
    authorize @supplier
    if @supplier.save
      redirect_to inventory_supplier_path(@supplier), notice: t("inventory.suppliers.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @supplier = find_supplier
    authorize @supplier
  end

  def update
    @supplier = find_supplier
    authorize @supplier
    if @supplier.update(supplier_params)
      redirect_to inventory_supplier_path(@supplier), notice: t("inventory.suppliers.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @supplier = find_supplier
    authorize @supplier
    if @supplier.destroy
      redirect_to inventory_suppliers_path, notice: t("inventory.suppliers.destroyed")
    else
      redirect_to inventory_suppliers_path, alert: @supplier.errors.full_messages.to_sentence
    end
  end

  private

  def find_supplier
    policy_scope(Supplier).find(params[:id])
  end

  def supplier_params
    params.require(:supplier).permit(
      :name, :primary_mobile, :secondary_mobile,
      :latitude, :longitude, :address, :notes
    )
  end
end
