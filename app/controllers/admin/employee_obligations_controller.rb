class Admin::EmployeeObligationsController < Admin::BaseController
  before_action :set_obligation, only: [ :show, :edit, :update, :pause, :resume, :cancel ]

  def index
    authorize EmployeeObligation
    @obligations = policy_scope(EmployeeObligation)
                     .includes({ user: { profile_photo_attachment: :blob } }, :created_by)
                     .order(created_at: :desc)
    @obligations = @obligations.where(user_id: params[:user_id]) if params[:user_id].present?
    @obligations = @obligations.where(status: params[:status])   if params[:status].present?
  end

  def show
    authorize @obligation
  end

  def new
    @obligation = EmployeeObligation.new(user_id: params[:user_id])
    authorize @obligation
    load_employees
  end

  def create
    @obligation = EmployeeObligation.new(obligation_params)
    @obligation.business         = current_user.business
    @obligation.created_by       = current_user
    @obligation.remaining_amount = @obligation.total_amount
    @obligation.installments_count = derive_installments_count(@obligation)
    authorize @obligation

    if @obligation.save
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.created")
    else
      load_employees
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @obligation
    load_employees
  end

  def update
    authorize @obligation
    attrs = obligation_params
    new_obligation = @obligation.dup.tap { |o| o.assign_attributes(attrs) }
    attrs_with_count = attrs.merge(
      installments_count: derive_installments_count(new_obligation)
    )

    if @obligation.update(attrs_with_count)
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.updated")
    else
      load_employees
      render :edit, status: :unprocessable_entity
    end
  end

  def pause
    authorize @obligation
    if @obligation.active?
      @obligation.update!(status: :paused)
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.paused")
    else
      redirect_to admin_employee_obligation_path(@obligation),
                  alert: t("admin.employee_obligations.cannot_pause")
    end
  end

  def resume
    authorize @obligation
    if @obligation.paused?
      @obligation.update!(status: :active)
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.resumed")
    else
      redirect_to admin_employee_obligation_path(@obligation),
                  alert: t("admin.employee_obligations.cannot_resume")
    end
  end

  def cancel
    authorize @obligation
    if @obligation.active? || @obligation.paused?
      @obligation.update!(status: :cancelled)
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.cancelled")
    else
      redirect_to admin_employee_obligation_path(@obligation),
                  alert: t("admin.employee_obligations.cannot_cancel")
    end
  end

  private

  def set_obligation
    @obligation = policy_scope(EmployeeObligation).find(params[:id])
  end

  def obligation_params
    params.require(:employee_obligation).permit(
      :user_id, :obligation_type, :title, :description, :notes,
      :total_amount, :installment_amount,
      :start_month, :start_year, :end_month, :end_year,
      :auto_deduct
    )
  end

  def load_employees
    @employees = current_user.business.users.active.order(:first_name, :last_name)
  end

  def derive_installments_count(obligation)
    total = obligation.total_amount.to_f
    installment = obligation.installment_amount.to_f
    return 1 if total <= 0 || installment <= 0
    (total / installment).ceil
  end
end
