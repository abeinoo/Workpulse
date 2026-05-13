module Api
  module V1
    # Handles employee-facing check-in / check-out actions.
    class AttendanceController < BaseController
      def check_in
        branch = find_branch
        return render_not_found("Branch not found") unless branch

        result = Attendance::CheckInService.call(
          user:      current_user,
          branch:    branch,
          latitude:  params[:latitude],
          longitude: params[:longitude]
        )

        if result.success?
          render_success(attendance_json(result.record), status: :created)
        else
          render_error(result.error)
        end
      end

      def check_out
        branch = find_branch
        return render_not_found("Branch not found") unless branch

        result = Attendance::CheckOutService.call(
          user:      current_user,
          branch:    branch,
          latitude:  params[:latitude],
          longitude: params[:longitude]
        )

        if result.success?
          render_success(attendance_json(result.record))
        else
          render_error(result.error)
        end
      end

      # Today's attendance status — used by the mobile app on load.
      def today
        record = AttendanceRecord.find_by(user: current_user, date: Date.current)
        render_success(record ? attendance_json(record) : nil)
      end

      private

      def find_branch
        current_business.branches.active.find_by(id: params[:branch_id])
      end

      def attendance_json(record)
        record.slice(
          :id, :date, :status,
          :check_in_at,  :check_in_latitude,  :check_in_longitude,
          :check_out_at, :check_out_latitude,  :check_out_longitude,
          :worked_minutes, :late_minutes, :early_leave_minutes
        )
      end
    end
  end
end
