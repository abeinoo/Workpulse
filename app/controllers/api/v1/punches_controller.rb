module Api
  module V1
    # POST /api/v1/attendance/punch
    #
    # Single endpoint for biometric device attendance punches.
    # Determines check-in vs check-out automatically based on the employee's
    # attendance state for the resolved work_date.
    #
    # Required params:
    #   employee_id  – matched against employee_code (string) then user id
    #   timestamp    – ISO 8601 string with timezone offset
    #
    # Authentication:
    #   Authorization: Bearer <device_token>
    #   — or —
    #   X-Device-Token: <device_token>
    class PunchesController < BiometricBaseController
      TIMESTAMP_TOLERANCE = 24.hours

      def create
        employee = find_employee
        return render_not_found(I18n.t("api.punch.employee_not_found")) unless employee

        punched_at = parse_timestamp
        return render_error(I18n.t("api.punch.invalid_timestamp")) unless punched_at

        # if stale_timestamp?(punched_at)
        #   return render_error(I18n.t("api.punch.stale_timestamp"), status: :unprocessable_entity)
        # end

        result = Attendance::PunchService.call(
          employee:    employee,
          punched_at:  punched_at,
          business:    current_business,
          device:      current_device,
          ip_address:  request.remote_ip,
          raw_payload: punch_params.to_h
        )

        if result.success?
          render_success(punch_response(result))
        else
          render_error(result.error)
        end
      end

      private

      def find_employee
        identifier = punch_params[:employee_id]
        return nil if identifier.blank?

        current_business.users.active
                        .find_by(employee_code: identifier.to_s) ||
          current_business.users.active
                          .find_by(id: identifier)
      end

      def parse_timestamp
        Attendance::TimestampParser.parse(
          punch_params[:timestamp].to_s,
          source:   :biometric_device,
          business: current_business
        )
      end

      def stale_timestamp?(ts)
        ts < TIMESTAMP_TOLERANCE.ago || ts > TIMESTAMP_TOLERANCE.from_now
      end

      def punch_params
        params.permit(:employee_id, :timestamp)
      end

      def punch_response(result)
        tz = current_business.timezone_object
        {
          action:            result.action,
          work_date:         result.log&.work_date,
          punched_at:        result.log&.punched_at&.in_time_zone(tz)&.iso8601,
          attendance_record: result.record ? record_json(result.record, tz) : nil
        }
      end

      def record_json(record, tz = current_business.timezone_object)
        {
          id:           record.id,
          work_date:    record.work_date,
          check_in_at:  record.check_in_at&.in_time_zone(tz)&.iso8601,
          check_out_at: record.check_out_at&.in_time_zone(tz)&.iso8601,
          status:       record.status
        }
      end
    end
  end
end
