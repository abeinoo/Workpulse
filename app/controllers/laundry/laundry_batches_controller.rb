class Laundry::LaundryBatchesController < Laundry::BaseController
  def index
    authorize LaundryBatch
    @laundry_batches = policy_scope(LaundryBatch)
                        .with_status(params[:status])
                        .order(created_at: :desc)
                        .includes(:towel_type, :laundry_branch, :operator)
  end

  def show
    @laundry_batch = find_batch
    authorize @laundry_batch
    @consumptions = @laundry_batch.consumptions.includes(:product)
    @laundry_warehouse = laundry_warehouse
  end

  def new
    @laundry_batch = current_user.business.laundry_batches.build
    authorize @laundry_batch
    load_options
  end

  def create
    @laundry_batch = current_user.business.laundry_batches.build(batch_build_params)
    authorize @laundry_batch

    result = Laundry::LaundryBatchService.create(
      actor: current_user, laundry_branch_id: batch_build_params[:laundry_branch_id],
      towel_type_id: batch_build_params[:towel_type_id],
      operator_id: batch_build_params[:operator_id], notes: batch_build_params[:notes]
    )
    @laundry_batch = result.batch

    if result.ok?
      redirect_to laundry_laundry_batch_path(@laundry_batch), notice: t("laundry.batches.created")
    else
      load_options
      render :new, status: :unprocessable_entity
    end
  end

  def start
    @laundry_batch = find_batch
    authorize @laundry_batch, :start?
    result = Laundry::LaundryBatchService.new(@laundry_batch).start(actor: current_user, input_quantity: params[:input_quantity])
    redirect_with_result(result, :started)
  end

  def complete
    @laundry_batch = find_batch
    authorize @laundry_batch, :complete?
    result = Laundry::LaundryBatchService.new(@laundry_batch).complete(
      actor: current_user,
      output_clean_quantity: params[:output_clean_quantity],
      damaged_quantity: params[:damaged_quantity].presence || 0,
      disposed_quantity: params[:disposed_quantity].presence || 0
    )
    redirect_with_result(result, :completed)
  end

  def reverse
    @laundry_batch = find_batch
    authorize @laundry_batch, :reverse?
    result = Laundry::LaundryBatchService.new(@laundry_batch).reverse(actor: current_user, reason: params[:reason])
    redirect_with_result(result, :reversed)
  end

  private

  def find_batch
    policy_scope(LaundryBatch).find(params[:id])
  end

  def redirect_with_result(result, flash_key)
    if result.ok?
      redirect_to laundry_laundry_batch_path(@laundry_batch), notice: t("laundry.batches.#{flash_key}")
    else
      redirect_to laundry_laundry_batch_path(@laundry_batch), alert: result.error
    end
  end

  def laundry_warehouse
    current_user.business.warehouses.find_by(name: "Laundry Warehouse") ||
      current_user.business.warehouses.first
  end
  helper_method :laundry_warehouse

  def load_options
    @laundry_branches = current_user.business.branches.branch_type_laundry.active
    @towel_types = laundry_towel_types
    @operators = current_user.business.users.active.order(:first_name, :last_name)
  end

  def batch_build_params
    params.require(:laundry_batch).permit(:laundry_branch_id, :towel_type_id, :operator_id, :notes)
          .to_h.symbolize_keys
  end
end
