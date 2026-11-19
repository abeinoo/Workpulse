class Laundry::LaundryBatchConsumptionsController < Laundry::BaseController
  before_action :set_batch

  def create
    authorize @laundry_batch, :record_consumption?

    product = current_user.business.products.find(params[:product_id])
    # Only a warehouse the user may reach (WarehousePolicy::Scope — the user's
    # business, narrowed by User#inventory_warehouse_ids); anything else, another
    # business's included, is refused before any stock is touched.
    warehouse = policy_scope(Warehouse).find_by(id: params[:warehouse_id])
    raise Pundit::NotAuthorizedError if warehouse.nil?

    result = Laundry::LaundryBatchService.new(@laundry_batch)
                                         .record_consumption(actor: current_user, warehouse: warehouse,
                                                             product: product, quantity: params[:quantity])

    if result.ok?
      redirect_to laundry_laundry_batch_path(@laundry_batch), notice: t("laundry.batches.consumption_recorded")
    else
      redirect_to laundry_laundry_batch_path(@laundry_batch), alert: result.error
    end
  end

  private

  def set_batch
    @laundry_batch = policy_scope(LaundryBatch).find(params[:laundry_batch_id])
  end
end
