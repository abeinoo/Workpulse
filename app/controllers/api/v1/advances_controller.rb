module Api
  module V1
    class AdvancesController < BaseController
      before_action :set_advance, only: [ :show ]

      def index
        authorize Advance
        advances = policy_scope(Advance)
                     .includes(:user, :employee_request)
                     .order(issued_at: :desc)
        render_success(advances.map { |a| advance_json(a) })
      end

      def show
        authorize @advance
        render_success(advance_json(@advance))
      end

      private

      def set_advance
        @advance = policy_scope(Advance).find(params[:id])
      end

      def advance_json(advance)
        advance.slice(:id, :user_id, :total_amount, :remaining_amount, :status, :issued_at)
               .merge(repaid_amount: advance.repaid_amount)
      end
    end
  end
end
