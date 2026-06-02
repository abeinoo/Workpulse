module Api
  module V1
    class PayrollAdjustmentsController < BaseController
      before_action :set_period

      def index
        authorize PayrollAdjustment
        adjustments = policy_scope(PayrollAdjustment)
                        .where(payroll_period: @period)
                        .includes(:user, :created_by)
                        .order(created_at: :desc)
        render_success(adjustments.map { |a| adjustment_json(a) })
      end

      def create
        authorize PayrollAdjustment
        # Payroll lock: no new adjustments once the period has been processed/closed.
        return render_error(I18n.t("adjustments.errors.period_processed")) if @period.locked?

        adjustment = @period.payroll_adjustments.build(adjustment_params)
        adjustment.created_by = current_user

        unless adjustment.save
          return render_error(adjustment.errors.full_messages.join(", "))
        end

        result = Payroll::AdjustmentApplier.call(adjustment: adjustment)
        return render_error(result.error) unless result.success?

        log_adjustment_action!(:adjustment_added, adjustment)
        render_success(adjustment_json(adjustment), status: :created)
      end

      def destroy
        adjustment = policy_scope(PayrollAdjustment).find(params[:id])
        authorize adjustment

        ActiveRecord::Base.transaction do
          log_adjustment_action!(:adjustment_removed, adjustment)
          Payroll::AdjustmentRemover.call(adjustment: adjustment)
          adjustment.destroy!
        end
        render_success({ message: "Adjustment removed" })
      end

      private

      def set_period
        @period = policy_scope(PayrollPeriod).find(params[:payroll_period_id])
      end

      def adjustment_params
        params.require(:payroll_adjustment).permit(:user_id, :adjustment_type, :amount, :reason)
      end

      def adjustment_json(adjustment)
        adjustment.slice(:id, :adjustment_type, :amount, :reason, :created_at).merge(
          user_id:        adjustment.user_id,
          created_by_id:  adjustment.created_by_id,
          payroll_period_id: adjustment.payroll_period_id
        )
      end

      def log_adjustment_action!(action, adjustment)
        PayrollAuditLog.create!(
          payroll_period: @period,
          actor:          current_user,
          action_type:    action,
          metadata:       {
            adjustment_id:   adjustment.id,
            adjustment_type: adjustment.adjustment_type,
            amount:          adjustment.amount,
            user_id:         adjustment.user_id
          }.to_json
        )
      end
    end
  end
end
