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
  # context-aware notice instead of a static hint. Read-only. Payroll answers
  # through the Workforce contract Employee::InsuranceProfileEffects:
  # :none / :active / :mixed / :finalized (see the contract for their meaning).
  def set_payroll_notice
    @payroll_insurance_notice = Employee::InsuranceProfileEffects.payroll_notice_for(user: @employee)
  end

  def profile_params
    params.require(:employee_insurance_profile).permit(
      :insured, :employee_contribution_amount, :employer_contribution_amount,
      :insurance_start_date, :insurance_end_date, :insurance_number, :notes
    )
  end
end
