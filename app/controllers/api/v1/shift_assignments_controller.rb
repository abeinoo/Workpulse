module Api
  module V1
    class ShiftAssignmentsController < BaseController
      before_action :set_assignment, only: [ :show, :update, :destroy ]

      def index
        authorize ShiftAssignment
        assignments = policy_scope(ShiftAssignment).includes(:shift, :branch, :user)
        render_success(assignments.map { |a| assignment_json(a) })
      end

      def show
        authorize @assignment
        render_success(assignment_json(@assignment))
      end

      def create
        authorize ShiftAssignment
        result = Shifts::Assigner.call(business: current_business, params: assignment_params)

        if result.success?
          render_success(assignment_json(result.assignment), status: :created)
        else
          render_error(result.error)
        end
      end

      def update
        authorize @assignment
        # Only effective_to is editable after creation
        if @assignment.update(update_params)
          render_success(assignment_json(@assignment))
        else
          render_error("Failed to update assignment", errors: @assignment.errors.full_messages)
        end
      end

      def destroy
        authorize @assignment
        @assignment.destroy
        render_success({ message: "Assignment removed" })
      end

      private

      def set_assignment
        @assignment = policy_scope(ShiftAssignment).find(params[:id])
      end

      def assignment_params
        params.require(:shift_assignment).permit(:user_id, :shift_id, :branch_id, :effective_from, :effective_to)
      end

      def update_params
        params.require(:shift_assignment).permit(:effective_to)
      end

      def assignment_json(assignment)
        {
          id:             assignment.id,
          user_id:        assignment.user_id,
          shift_id:       assignment.shift_id,
          shift_name:     assignment.shift_name,
          branch_id:      assignment.branch_id,
          branch_name:    assignment.branch_name,
          effective_from: assignment.effective_from,
          effective_to:   assignment.effective_to
        }
      end
    end
  end
end
