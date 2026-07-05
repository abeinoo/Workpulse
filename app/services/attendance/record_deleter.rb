module Attendance
  # Soft-deletes an attendance record and recalculates the affected payroll
  # period, mirroring AdjustmentService's edit → audit → recalculate flow.
  # Deletion is blocked outright when the affected period is finalized/paid,
  # since those periods are immutable (see PayrollPeriod#locked?).
  class RecordDeleter
    include AuditLoggable

    Result = Struct.new(:success, :record, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(record:, deleted_by:, reason: nil)
      new(record: record, deleted_by: deleted_by, reason: reason).call
    end

    def initialize(record:, deleted_by:, reason: nil)
      @record      = record
      @deleted_by  = deleted_by
      @reason      = reason
    end

    def call
      return err(I18n.t("attendance.records.delete.already_deleted")) if @record.deleted?

      period = payroll_period
      return err(I18n.t("attendance.records.delete.blocked_#{period.lock_reason}")) if period&.locked?

      ActiveRecord::Base.transaction do
        @record.update!(deleted_at: Time.current, deleted_by: @deleted_by, deletion_notes: @reason)
        log_audit(
          actor:     @deleted_by,
          auditable: @record,
          action:    "delete_attendance",
          metadata:  { reason: @reason, work_date: @record.work_date, user_id: @record.user_id }
        )
      end

      recalculate_payroll_entry(period)
      Result.new(success: true, record: @record)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    private

    def business
      @business ||= @record.branch&.business || @record.user.business
    end

    def payroll_period
      PayrollPeriod.find_by(
        business:     business,
        period_year:  @record.work_date.year,
        period_month: @record.work_date.month
      )
    end

    def recalculate_payroll_entry(period)
      return unless period&.editable?

      Payroll::EntryRecalculator.call(user: @record.user, period: period, triggered_by: @deleted_by)
    rescue => e
      Rails.logger.error(
        "[Attendance::RecordDeleter] Payroll recalc failed attendance=#{@record.id} " \
        "user=#{@record.user_id}: #{e.class}: #{e.message}"
      )
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
