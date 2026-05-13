module Api
  module V1
    class PenaltyRulesController < BaseController
      before_action :set_shift
      before_action :set_rule, only: [ :update, :destroy ]

      def index
        authorize @shift, :show?
        render_success(@shift.penalty_rules.ordered_by_threshold)
      end

      def create
        authorize @shift, :update?
        rule = @shift.penalty_rules.new(rule_params)

        if rule.save
          render_success(rule, status: :created)
        else
          render_error("Failed to create penalty rule", errors: rule.errors.full_messages)
        end
      end

      def update
        authorize @shift, :update?

        if @rule.update(rule_params)
          render_success(@rule)
        else
          render_error("Failed to update penalty rule", errors: @rule.errors.full_messages)
        end
      end

      def destroy
        authorize @shift, :update?
        @rule.destroy
        render_success({ message: "Penalty rule deleted" })
      end

      private

      def set_shift
        @shift = current_business.shifts.find(params[:shift_id])
      end

      def set_rule
        @rule = @shift.penalty_rules.find(params[:id])
      end

      def rule_params
        params.require(:penalty_rule).permit(:rule_type, :threshold_minutes, :deduction_type, :deduction_value)
      end
    end
  end
end
