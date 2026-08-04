module Api
  module V1
    class PayrollPeriodsController < BaseController
      before_action :set_period, only: [ :show, :finalize, :mark_paid, :regenerate,
                                          :complete_branch_review, :submit_for_review,
                                          :approve_all_pending, :reopen, :destroy ]

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

      def submit_for_review
        authorize @period, :submit_for_review?
        result = Payroll::SubmitForReview.call(period: @period, by: current_user)
        handle_result(result)
      end

      def approve_all_pending
        authorize @period, :approve_all_pending?
        return render_error("Period is not reviewable") unless @period.editable?

        pending_items = PayrollLineItem
                          .joins(:payroll_entry)
                          .where(payroll_entries: { payroll_period_id: @period.id })
                          .where(review_status: :pending_review)

        return render_error("No pending items") if pending_items.empty?

        entry_ids = Set.new
        approved  = 0
        ActiveRecord::Base.transaction do
          pending_items.find_each do |item|
            item.update!(
              review_status: :approved,
              reviewed_by:   current_user,
              reviewed_at:   Time.current
            )
            entry_ids << item.payroll_entry_id
            approved  += 1
          end
          PayrollEntry.where(id: entry_ids.to_a).find_each(&:recalculate_totals!)
        end

        render_success(period_json(@period.reload).merge(approved_count: approved))
      end

      def reopen
        authorize @period, :reopen?
        result = Payroll::Reopener.call(period: @period, by: current_user, reason: params[:reason])
        handle_result(result)
      end

      def destroy
        authorize @period, :destroy?
        @period.destroy!
        render_success(period_label: @period.period_label, status: "deleted")
      rescue StandardError => e
        render_error(e.message)
      end

      # Branch reviewer marks all their authorized pending branch reviews as complete.
      def complete_branch_review
        authorize @period, :complete_branch_review?

        pending_reviews = @period.payroll_period_branch_reviews
                                 .where(branch_id: authorized_review_branch_ids, status: :pending)
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

      # Branches the current user is allowed to complete reviews for. Honors
      # the configured `complete_branch_review` data scope.
      def authorized_review_branch_ids
        case current_user.scope_for(:complete_branch_review)
        when "business"
          current_user.business.branches.pluck(:id)
        else
          (current_user.managed_branch_ids + current_user.area_managed_branch_ids).uniq
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
          # entry_count is an aggregate — only expose to analytics consumers.
          data[:entry_count] = period.payroll_entries.size if current_user.can?(:view_payroll_analytics)
        end

        data
      end

      def entry_summary_json(entry)
        entry.slice(
          :id, :user_id, :salary_type, :base_salary,
          :working_days, :days_worked, :total_deductions,
          :total_overtime, :total_bonuses, :already_paid_total,
          :advances_deducted, :obligations_deducted, :net_salary,
          :status
        )
      end
    end
  end
end
