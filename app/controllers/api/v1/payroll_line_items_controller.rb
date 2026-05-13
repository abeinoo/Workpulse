module Api
  module V1
    class PayrollLineItemsController < BaseController
      before_action :set_line_item

      def approve
        authorize @line_item, :approve?
        result = Payroll::LineItemReviewer.call(
          line_item:   @line_item,
          action:      "approve",
          reviewed_by: current_user,
          notes:       params[:notes]
        )
        handle_result(result)
      end

      def reject
        authorize @line_item, :reject?
        result = Payroll::LineItemReviewer.call(
          line_item:   @line_item,
          action:      "reject",
          reviewed_by: current_user,
          notes:       params[:notes]
        )
        handle_result(result)
      end

      private

      def set_line_item
        @line_item = policy_scope(PayrollLineItem).find(params[:id])
      end

      def handle_result(result)
        if result.success?
          render_success(line_item_json(result.line_item))
        else
          render_error(result.error)
        end
      end

      def line_item_json(li)
        li.slice(
          :id, :item_type, :amount, :description,
          :source_type, :source_id,
          :review_status, :reviewed_at, :review_notes
        ).merge(reviewed_by_id: li.reviewed_by_id)
      end
    end
  end
end
