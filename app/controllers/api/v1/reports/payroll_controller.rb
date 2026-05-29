module Api
  module V1
    module Reports
      class PayrollController < BaseController
        # Aggregated payroll reports (summary totals + CSV with totals row) are
        # analytics endpoints. A user with only `view_payroll` cannot query
        # them; they need the explicit `view_payroll_analytics` grant.
        before_action :require_payroll_analytics!

        def summary
          period  = find_period
          authorize period, :show?
          entries = scoped_entries(period)
          render_success(::Reports::PayrollSummary.call(period: period, entries: entries))
        end

        def export
          period  = find_period
          authorize period, :show?
          entries = scoped_entries(period)
          csv = ::Reports::PayrollCsvExporter.call(period: period, business: current_user.business, entries: entries)
          send_data csv,
                    filename:    "payroll_#{period.period_label.parameterize}.csv",
                    type:        "text/csv",
                    disposition: "attachment"
        end

        private

        def require_payroll_analytics!
          render_unauthorized unless current_user.can?(:view_payroll_analytics)
        end

        def find_period
          policy_scope(PayrollPeriod).find(params[:payroll_period_id])
        end

        def scoped_entries(period)
          policy_scope(PayrollEntry).where(payroll_period: period)
        end
      end
    end
  end
end
