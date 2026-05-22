module Api
  module V1
    module Reports
      class PayrollController < BaseController
        def summary
          period = find_period
          authorize period, :show?
          render_success(::Reports::PayrollSummary.call(period: period))
        end

        def export
          period = find_period
          authorize period, :show?
          csv = ::Reports::PayrollCsvExporter.call(period: period, business: current_user.business)
          send_data csv,
                    filename:    "payroll_#{period.period_label.parameterize}.csv",
                    type:        "text/csv",
                    disposition: "attachment"
        end

        private

        def find_period
          policy_scope(PayrollPeriod).find(params[:payroll_period_id])
        end
      end
    end
  end
end
