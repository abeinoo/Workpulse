module Api
  module V1
    class PayrollEntriesController < BaseController
      before_action :set_entry, only: [ :show, :update ]

      def index
        authorize PayrollEntry
        entries = policy_scope(PayrollEntry)
                    .includes(:user, :payroll_period)
                    .order(created_at: :desc)
        entries = entries.where(payroll_period_id: params[:payroll_period_id]) if params[:payroll_period_id]
        render_success(entries.map { |e| entry_json(e) })
      end

      def show
        authorize @entry
        render_success(entry_json(@entry, detailed: true))
      end

      def update
        authorize @entry
        return render_error("Cannot modify a paid payroll entry") if @entry.payroll_period.paid?

        if entry_params[:bonus_amount].present?
          add_bonus(@entry, entry_params[:bonus_amount].to_f, entry_params[:bonus_description])
        end

        @entry.update!(notes: entry_params[:notes]) if entry_params[:notes]
        render_success(entry_json(@entry, detailed: true))
      rescue ActiveRecord::RecordInvalid => e
        render_error(e.record.errors.full_messages.join(", "))
      end

      private

      def set_entry
        @entry = policy_scope(PayrollEntry)
                   .includes(:payroll_line_items, :payroll_period)
                   .find(params[:id])
      end

      def entry_params
        params.require(:payroll_entry).permit(:bonus_amount, :bonus_description, :notes)
      end

      def add_bonus(entry, amount, description)
        return if amount <= 0

        ActiveRecord::Base.transaction do
          entry.payroll_line_items.create!(
            item_type:     "cash_incentive",
            amount:        amount.round(2),
            description:   description.presence || "Manual incentive",
            review_status: "approved",
            already_paid:  false
          )
          entry.recalculate_totals!
        end
      end

      def entry_json(entry, detailed: false)
        data = entry.slice(
          :id, :user_id, :salary_type, :base_salary,
          :working_days, :days_worked, :total_deductions,
          :total_overtime, :total_bonuses, :already_paid_total,
          :advances_deducted, :obligations_deducted,
          :net_salary, :status, :notes
        ).merge(
          payroll_period_id: entry.payroll_period_id,
          gross_salary:      entry.gross_salary,
          total_adjustments: entry.total_adjustments,
          currency:          current_user.business.currency
        )

        if detailed
          data[:pending_review_count] = entry.payroll_line_items.count(&:pending_review?)
          data[:line_items]           = entry.payroll_line_items.map { |li| line_item_json(li) }
          data[:attendance]           = attendance_summary(entry)
        end

        data
      end

      def line_item_json(li)
        li.slice(
          :id, :item_type, :amount, :description,
          :source_type, :source_id, :already_paid,
          :review_status, :reviewed_at, :review_notes
        ).merge(reviewed_by_id: li.reviewed_by_id)
      end

      def attendance_summary(entry)
        records = AttendanceRecord
                    .where(user_id: entry.user_id)
                    .for_period(
                      entry.payroll_period.period_start,
                      entry.payroll_period.period_end
                    )
                    .includes(shift_assignment: :shift)
        {
          total_worked_minutes:      records.sum(:worked_minutes),
          total_overtime_minutes:    records.select { |r| r.worked_minutes.to_i > 0 }.sum { |r|
                                       shift = r.shift_assignment&.shift
                                       next 0 unless shift
                                       [ r.worked_minutes - shift.duration_minutes, 0 ].max
                                     },
          total_late_minutes:        records.sum(:late_minutes),
          total_early_leave_minutes: records.sum(:early_leave_minutes),
          days_present:              records.count { |r| r.present? || r.late? || r.early_leave? },
          days_absent:               records.count(&:absent?)
        }
      end
    end
  end
end
