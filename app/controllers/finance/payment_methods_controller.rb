class Finance::PaymentMethodsController < Finance::BaseController
  before_action :set_payment_method, only: %i[edit update destroy move_up move_down]

  def index
    authorize PaymentMethod
    @payment_methods = policy_scope(PaymentMethod).ordered
  end

  def new
    @payment_method = PaymentMethod.new(
      business: current_user.business,
      active: true, supports_refunds: true, settlement_type: "other"
    )
    authorize @payment_method
  end

  def create
    @payment_method = PaymentMethod.new(
      payment_method_params.merge(business: current_user.business)
    )
    @payment_method.position = next_position if @payment_method.position.blank?
    authorize @payment_method

    if @payment_method.save
      redirect_to finance_payment_methods_path, notice: t("finance.payment_methods.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @payment_method
  end

  def update
    authorize @payment_method

    if @payment_method.update(payment_method_params)
      redirect_to finance_payment_methods_path, notice: t("finance.payment_methods.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @payment_method

    if @payment_method.destroy
      redirect_to finance_payment_methods_path, notice: t("finance.payment_methods.deleted")
    else
      redirect_to finance_payment_methods_path,
                  alert: t("finance.payment_methods.delete_failed")
    end
  end

  def move_up
    authorize @payment_method, :update?
    swap_position(@payment_method, :up)
    redirect_to finance_payment_methods_path
  end

  def move_down
    authorize @payment_method, :update?
    swap_position(@payment_method, :down)
    redirect_to finance_payment_methods_path
  end

  private

  def set_payment_method
    @payment_method = policy_scope(PaymentMethod).find(params[:id])
  end

  def payment_method_params
    params.require(:payment_method).permit(
      :name, :name_ar, :settlement_type, :supports_refunds, :active, :position, :include_in_pos_verification
    )
  end

  def next_position
    (policy_scope(PaymentMethod).maximum(:position) || -1) + 1
  end

  def swap_position(record, direction)
    sorted = policy_scope(PaymentMethod).ordered.to_a
    idx    = sorted.index(record)
    return unless idx

    swap_idx = direction == :up ? idx - 1 : idx + 1
    return unless swap_idx.between?(0, sorted.length - 1)

    neighbour  = sorted[swap_idx]
    pos_a      = record.position
    pos_b      = neighbour.position

    PaymentMethod.transaction do
      record.update_column(:position, pos_b)
      neighbour.update_column(:position, pos_a)
    end
  end
end
