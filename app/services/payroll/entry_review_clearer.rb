module Payroll
  # Clears the lightweight "Needs Review" flag on a single PayrollEntry.
  #
  # This is only an acknowledgement that the reviewer has seen the changes
  # made to this employee since the flag was last cleared — it is NOT an
  # approval workflow and does not touch the period's status. Anyone who can
  # complete Branch Review (the existing reviewer persona) can clear it.
  #
  # One exception blocks Finalize: an entry changed by Recalculate Payroll
  # (recalculation_review_required, Payroll::PeriodRecalculator). Clearing the
  # entry here also clears that requirement, and the audit entry records it.
  class EntryReviewClearer
    Result = Struct.new(:success, :entry, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(entry:, actor:)
      new(entry: entry, actor: actor).call
    end

    def initialize(entry:, actor:)
      @entry = entry
      @actor = actor
    end

    def call
      return err(I18n.t("payroll.needs_review.errors.permission")) unless @actor.can?(:complete_branch_review)

      period = @entry.payroll_period
      return err(I18n.t("payroll.needs_review.errors.locked")) unless period&.editable?
      return err(I18n.t("payroll.needs_review.errors.not_flagged")) unless @entry.needs_review? || @entry.recalculation_review_required?

      @recalculation_reviewed = @entry.recalculation_review_required?
      clear = lambda do
        @entry.update!(needs_review: false, recalculation_review_required: false)
        write_audit
      end
      # Acknowledging a recalculation's figures is what unblocks Finalize, so
      # that clearing and its audit entry commit together or not at all (the
      # audit write fails closed). The plain flag keeps its fail-open audit.
      @recalculation_reviewed ? ActiveRecord::Base.transaction { clear.call } : clear.call
      Result.new(success: true, entry: @entry)
    rescue => e
      Rails.logger.error("[Payroll::EntryReviewClearer] entry=#{@entry.id} failed: #{e.message}")
      err(e.message)
    end

    private

    def write_audit
      PayrollAuditLog.create!(
        payroll_period: @entry.payroll_period,
        actor:          @actor,
        action_type:    "entry_review_cleared",
        metadata:       {
          payroll_entry_id: @entry.id,
          employee_id:      @entry.user_id,
          recalculation_reviewed: @recalculation_reviewed
        }.to_json
      )
    rescue => e
      raise if @recalculation_reviewed

      Rails.logger.error("[PayrollAuditLog] entry_review_cleared write failed: #{e.message}")
    end

    def err(msg)
      Result.new(success: false, error: msg)
    end
  end
end
