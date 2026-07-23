class Laundry::TowelTransfersController < Laundry::BaseController
  def index
    authorize TowelTransfer
    @towel_transfers = policy_scope(TowelTransfer)
                        .with_status(params[:status])
                        .for_branch(params[:branch_id])
                        .order(created_at: :desc)
                        .includes(items: :towel_type, source_branch: [], destination_branch: [], created_by: [])
    @filter_branches = assignable_branches
  end

  def show
    @towel_transfer = find_transfer
    authorize @towel_transfer
  end

  def new
    @towel_transfer = current_user.business.towel_transfers.build
    @towel_transfer.items.build
    authorize @towel_transfer
    load_options
  end

  def create
    params_with_inferred_status = transfer_params.merge(towel_status: inferred_or_manual_towel_status)

    # Authorize against an unsaved, params-built instance BEFORE the service
    # persists anything — TowelTransferCreator.create always saves, so
    # authorizing after the fact would mean an unauthorized write already
    # happened.
    @towel_transfer = current_user.business.towel_transfers.build(params_with_inferred_status)
    authorize @towel_transfer

    result = Laundry::TowelTransferCreator.create(actor: current_user, params: params_with_inferred_status)
    @towel_transfer = result.transfer

    if result.ok?
      redirect_to laundry_towel_transfer_path(@towel_transfer), notice: t("laundry.towel_transfers.created")
    else
      @towel_transfer.items.build if @towel_transfer.items.empty?
      load_options
      render :new, status: :unprocessable_entity
    end
  end

  def mark_dispatched
    @towel_transfer = find_transfer
    authorize @towel_transfer, :dispatch?
    result = Laundry::TowelTransferCreator.new(@towel_transfer).dispatch(actor: current_user)
    redirect_with_result(result, :dispatched)
  end

  def receive
    @towel_transfer = find_transfer
    authorize @towel_transfer, :receive?
    result = Laundry::TowelTransferCreator.new(@towel_transfer)
                                          .receive(actor: current_user,
                                                   confirmed_quantities: params.fetch(:confirmed_quantities, {}).to_unsafe_h)
    redirect_with_result(result, :received)
  end

  def cancel
    @towel_transfer = find_transfer
    authorize @towel_transfer, :cancel?
    result = Laundry::TowelTransferCreator.new(@towel_transfer).cancel(actor: current_user, reason: params[:cancellation_reason])
    redirect_with_result(result, :cancelled)
  end

  private

  def find_transfer
    policy_scope(TowelTransfer).find(params[:id])
  end

  def redirect_with_result(result, flash_key)
    if result.ok?
      redirect_to laundry_towel_transfer_path(@towel_transfer), notice: t("laundry.towel_transfers.#{flash_key}")
    else
      redirect_to laundry_towel_transfer_path(@towel_transfer), alert: result.error
    end
  end

  # Only sales/laundry branches participate in the normal transfer workflow
  # (see Branch.laundry_transfer_eligible and TowelTransfer.infer_towel_status)
  # — warehouse/headquarters/maintenance/other branches are excluded from
  # these selectors rather than offered and then rejected on submit.
  def load_options
    @branches   = assignable_branches(:create_towel_transfers, :view_towel_balances)
                   .merge(Branch.laundry_transfer_eligible)
    @towel_types = laundry_towel_types
  end

  # The condition is always derived from the actual branch types server side
  # — there is no user-facing override. A combination that can't be inferred
  # (see TowelTransfer.infer_towel_status) returns nil here, which the
  # model's towel_status presence validation then rejects with a clear error.
  def inferred_or_manual_towel_status
    source      = current_user.business.branches.find_by(id: transfer_params[:source_branch_id])
    destination = current_user.business.branches.find_by(id: transfer_params[:destination_branch_id])

    TowelTransfer.infer_towel_status(source, destination)
  end

  def transfer_params
    params.require(:towel_transfer).permit(
      :source_branch_id, :destination_branch_id, :notes,
      items_attributes: [ :id, :towel_type_id, :declared_quantity, :_destroy ]
    ).to_h.symbolize_keys
  end
end
