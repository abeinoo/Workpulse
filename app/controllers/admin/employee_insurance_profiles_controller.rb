class Admin::EmployeeInsuranceProfilesController < Admin::BaseController
  before_action :set_employee
  before_action :set_profile
  before_action :set_payroll_notice, only: %i[edit update]

  def edit
    authorize @profile
  end

  def update
    authorize @profile

    result = Employee::InsuranceProfileUpdater.call(user_id: @employee.id, actor: current_user, attrs: profile_params)

    if result.ok?
      redirect_to admin_user_path(@employee), notice: t("flash.insurance_profile_updated")
    else
      @profile = result.profile
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_employee
    @employee = current_user.business.users.find(params[:user_id])
  end

  # A standalone unsaved profile, never @employee.build_employee_insurance_profile:
  # User has_one :employee_insurance_profile, dependent: :destroy, so building
  # through the association deletes an existing profile the policy scope did
  # not return — before authorization runs (SEC-P8-1).
  def set_profile
    @profile = policy_scope(EmployeeInsuranceProfile).find_by(user: @employee) ||
               EmployeeInsuranceProfile.new(user: @employee, business: @employee.business)
  end

  # Which payroll periods this edit could affect, so the view can show a
  # context-aware notice instead of a static hint. Read-only — does not
  # change what payroll actually does with the insurance snapshot (see
  # Payroll::EntryCalculator#resolve_insurance_snapshot for the real rule).
  #
  #   :none     — employee has never appeared in any payroll period
  #   :active   — exactly one non-finalized period (draft/under_review/
  #               branch_review_completed) has an entry for them; any
  #               already-finalized history is irrelevant noise
  #   :finalized — every period they appear in is finalized/paid; nothing
  #               currently open to reflect the change into
  #   :mixed    — more than one non-finalized period exists at once
  #               (e.g. next month's draft generated before this month's
  #               review finished) — ambiguous which one to name specifically
  def set_payroll_notice
    periods = PayrollPeriod.where(id: @employee.payroll_entries.select(:payroll_period_id))
    active  = periods.reject(&:locked?)

    @payroll_insurance_notice =
      if periods.none?
        :none
      elsif active.size > 1
        :mixed
      elsif active.size == 1
        :active
      else
        :finalized
      end
  end

  def profile_params
    params.require(:employee_insurance_profile).permit(
      :insured, :employee_contribution_amount, :employer_contribution_amount,
      :insurance_start_date, :insurance_end_date, :insurance_number, :notes
    )
  end
end
