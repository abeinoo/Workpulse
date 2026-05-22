module Api
  module V1
    class PayrollPeriodsController < BaseController
      before_action :set_period, only: [ :show, :finalize, :mark_paid, :regenerate, :complete_branch_review ]

      def index
        authorize PayrollPeriod
        periods = policy_scope(PayrollPeriod)
                    .includes(:generated_by, :finalized_by, :payroll_entries)
                    .order(period_year: :desc, period_month: :desc)
        render_success(periods.map { |p| period_json(p) })
      end

      def show
        authorize @period
        render_success(period_json(@period, detailed: true))
      end

      def create
        authorize PayrollPeriod

        result = Payroll::PeriodGenerator.call(
          business:     current_business,
          year:         period_params[:year].to_i,
          month:        period_params[:month].to_i,
          generated_by: current_user
        )
        render_success(period_json(result), status: :created)
      rescue ArgumentError, RuntimeError => e
        render_error(e.message)
      end

      def finalize
        authorize @period, :finalize?
        result = Payroll::Approver.advance(period: @period, by: current_user)
        handle_result(result)
      end

      def mark_paid
        authorize @period, :mark_paid?
        result = Payroll::Approver.advance(period: @period, by: current_user)
        handle_result(result)
      end

      def regenerate
        authorize @period, :regenerate?
        result = Payroll::Regenerator.call(period: @period, regenerated_by: current_user)
        handle_result(result)
      end

      # Branch manager marks all their branch reviews as complete.
      def complete_branch_review
        authorize @period, :complete_branch_review?

        managed_branch_ids = Branch.where(branch_manager_id: current_user.id).pluck(:id)
        pending_reviews    = @period.payroll_period_branch_reviews
                                    .where(branch_id: managed_branch_ids, status: :pending)
                                    .includes(:branch)

        return render_error("No pending branch reviews found for your branches") if pending_reviews.empty?

        error = nil
        pending_reviews.each do |review|
          result = Payroll::BranchReviewCompleter.call(
            period:   @period,
            branch:   review.branch,
            reviewer: current_user,
            notes:    params[:notes]
          )
          error ||= result.error unless result.success?
        end

        error ? render_error(error) : render_success(period_json(@period.reload))
      end

      private

      def set_period
        @period = policy_scope(PayrollPeriod).find(params[:id])
      end

      def period_params
        params.require(:payroll_period).permit(:year, :month)
      end

      def handle_result(result)
        if result.success?
          render_success(period_json(result.period))
        else
          render_error(result.error)
        end
      end

      def period_json(period, detailed: false)
        data = {
          id:              period.id,
          status:          period.status,
          period_year:     period.period_year,
          period_month:    period.period_month,
          working_days:    period.working_days,
          generated_at:    period.generated_at,
          finalized_at:    period.finalized_at,
          period_label:    period.period_label,
          generated_by_id: period.generated_by_id,
          finalized_by_id: period.finalized_by_id
        }

        if detailed
          data[:entries]        = period.payroll_entries.includes(:user).map { |e| entry_summary_json(e) }
          data[:branch_reviews] = period.payroll_period_branch_reviews.includes(:branch, :reviewer).map do |r|
            {
              branch_id:    r.branch_id,
              branch_name:  r.branch.name,
              reviewer_id:  r.reviewer_id,
              status:       r.status,
              completed_at: r.completed_at
            }
          end
        else
          data[:entry_count] = period.payroll_entries.size
        end

        data
      end

      def entry_summary_json(entry)
        entry.slice(
          :id, :user_id, :salary_type, :base_salary,
          :working_days, :days_worked, :total_deductions,
          :total_overtime, :total_bonuses, :advances_deducted, :obligations_deducted, :net_salary,
          :status
        )
      end
    end
  end
end
