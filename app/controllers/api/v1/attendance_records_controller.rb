module Api
  module V1
    # Manager-facing: view and adjust historical attendance records.
    class AttendanceRecordsController < BaseController
      before_action :set_record, only: [ :show, :update ]

      def index
        authorize AttendanceRecord
        records = policy_scope(AttendanceRecord)
                    .includes(:user, :branch, shift_assignment: :shift)
                    .for_period(filter_start, filter_end)
                    .order(date: :desc, user_id: :asc)

        render_success(records.map { |r| record_json(r) })
      end

      def show
        authorize @record
        render_success(record_json(@record, include_adjustments: true))
      end

      def update
        authorize @record

        result = Attendance::AdjustmentService.call(
          record:      @record,
          adjusted_by: current_user,
          params:      adjustment_params
        )

        if result.success?
          render_success(record_json(result.record, include_adjustments: true))
        else
          render_error(result.error)
        end
      end

      private

      def set_record
        @record = policy_scope(AttendanceRecord).find(params[:id])
      end

      def filter_start
        params[:start_date] ? (Date.parse(params[:start_date]) rescue current_business_date.beginning_of_month) : current_business_date.beginning_of_month
      end

      def filter_end
        params[:end_date] ? (Date.parse(params[:end_date]) rescue current_business_date.end_of_month) : current_business_date.end_of_month
      end

      # Today's date in the business timezone. Using Date.current (UTC) would give the wrong
      # calendar day for businesses with a positive UTC offset near midnight.
      def current_business_date
        Time.current.in_time_zone(current_business.timezone_object).to_date
      end

      def adjustment_params
        params.require(:attendance_record).permit(:check_in_at, :check_out_at, :reason)
      end

      def record_json(record, include_adjustments: false)
        tz = current_business.timezone_object
        data = record.slice(
          :id, :user_id, :branch_id, :date, :status,
          :worked_minutes, :late_minutes, :early_leave_minutes
        ).merge(
          check_in_at:  record.check_in_at&.in_time_zone(tz)&.iso8601,
          check_out_at: record.check_out_at&.in_time_zone(tz)&.iso8601
        )

        if include_adjustments
          data[:adjustments] = record.attendance_adjustments.order(created_at: :asc).map { |adj|
            adj.slice(:id, :field_name, :old_value, :new_value, :reason, :created_at)
               .merge(adjusted_by_id: adj.adjusted_by_id)
          }
        end

        data
      end
    end
  end
end
