module Api
  module V1
    class ShiftsController < BaseController
      before_action :set_shift, only: [ :show, :update, :destroy ]

      def index
        shifts = policy_scope(Shift)
        render_success(shifts.map { |s| shift_json(s) })
      end

      def show
        authorize @shift
        render_success(shift_json(@shift, include_rules: true))
      end

      def create
        authorize Shift
        shift = current_business.shifts.new(shift_params)

        if shift.save
          render_success(shift_json(shift), status: :created)
        else
          render_error("Failed to create shift", errors: shift.errors.full_messages)
        end
      end

      def update
        authorize @shift

        if @shift.update(shift_params)
          render_success(shift_json(@shift))
        else
          render_error("Failed to update shift", errors: @shift.errors.full_messages)
        end
      end

      def destroy
        authorize @shift

        if @shift.destroy
          render_success({ message: "Shift deleted" })
        else
          render_error("Cannot delete a shift with active assignments", errors: @shift.errors.full_messages)
        end
      end

      private

      def set_shift
        @shift = current_business.shifts.find(params[:id])
      end

      def shift_params
        params.require(:shift).permit(:name, :shift_type, :start_time, :end_time, :required_hours, :active)
      end

      def shift_json(shift, include_rules: false)
        data = shift.slice(:id, :name, :shift_type, :start_time, :end_time, :required_hours, :active)
        data[:penalty_rules] = shift.penalty_rules.ordered_by_threshold if include_rules
        data
      end
    end
  end
end
