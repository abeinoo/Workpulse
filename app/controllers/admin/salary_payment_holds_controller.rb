module Admin
  # Places and releases Salary Payment Holds from the employee page. Thin:
  # authorize (SalaryPaymentHoldPolicy), call the service, redirect.
  class SalaryPaymentHoldsController < ApplicationController
    before_action :authenticate_user!

    def create
      employee = User.where(business_id: current_user.business_id).find(params[:user_id])
      authorize SalaryPaymentHold.new(business_id: current_user.business_id, user_id: employee.id), :create?

      result = Payroll::SalaryHoldCreator.new(actor: current_user, user_id: employee.id, reason: params[:reason],
                                              effective_from: params[:effective_from], notes: params[:notes]).call
      if result.ok?
        redirect_to admin_user_path(employee), notice: t("salary_payment_holds.flash.created")
      else
        redirect_to admin_user_path(employee), alert: result.error
      end
    end

    def release
      hold = SalaryPaymentHold.where(business_id: current_user.business_id).find(params[:id])
      authorize hold, :release?

      result = Payroll::SalaryHoldReleaser.new(actor: current_user, hold_id: hold.id,
                                               release_reason: params[:release_reason]).call
      if result.ok?
        redirect_to admin_user_path(hold.user_id), notice: t("salary_payment_holds.flash.released")
      else
        redirect_to admin_user_path(hold.user_id), alert: result.error
      end
    end
  end
end
