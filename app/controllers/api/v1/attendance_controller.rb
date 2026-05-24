module Api
  module V1
    # Handles employee-facing check-in / check-out actions.
    class AttendanceController < BaseController
      before_action :require_mobile_attendance_allowed!, only: [:check_in, :check_out]

      def check_in
        branch = find_checkin_branch
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
        branch = find_checkout_branch
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
      # Uses business timezone so employees in UTC+3 after midnight UTC see today correctly.
      def today
        today_date = BusinessDay.work_date_for(Time.current, context: current_business)
        record = AttendanceRecord.find_by(user: current_user, work_date: today_date)
        render_success(record ? attendance_json(record) : nil)
      end

      private

      # Branch eligibility at check-in must come from an active ShiftAssignment.
      def find_checkin_branch
        return nil unless params[:branch_id].present?

        ShiftAssignment.current
                       .where(user: current_user, branch_id: params[:branch_id])
                       .first&.branch
      end

      # At check-out the shift was already validated at check-in. Only need the
      # branch object for geolocation, so look it up directly.
      def find_checkout_branch
        return nil unless params[:branch_id].present?

        current_business.branches.active.find_by(id: params[:branch_id])
      end

      def attendance_json(record)
        record.slice(
          :id, :work_date, :date, :status,
          :check_in_at,  :check_in_latitude,  :check_in_longitude,
          :check_out_at, :check_out_latitude,  :check_out_longitude,
          :worked_minutes, :late_minutes, :early_leave_minutes
        ).merge(timezone: current_business.timezone)
      end

      def require_mobile_attendance_allowed!
        return if current_user.allow_mobile_attendance?

        log_mobile_rejection
        render_error(
          I18n.t("api.punch.mobile_attendance_not_allowed"),
          status: :forbidden
        )
      end

      def log_mobile_rejection
        BiometricPunchLog.create!(
          business:    current_business,
          employee:    current_user,
          punched_at:  Time.current,
          received_at: Time.current,
          source:      "mobile",
          action:      "rejected_not_allowed",
          ip_address:  request.remote_ip,
          error_message: I18n.t("api.punch.mobile_attendance_not_allowed")
        )
      rescue ActiveRecord::RecordInvalid
        # Non-fatal — don't let a logging failure block the error response
      end
    end
  end
end
