module Payroll
  # Clears the "Needs Review" flag on every currently-flagged entry in a
  # period — either every flagged entry (period-wide "Mark All Reviewed") or
  # a restricted set (e.g. a branch manager clearing only their branch),
  # delegating each entry to Payroll::EntryReviewClearer so the permission
  # check, audit trail, and editability guard are shared with the single-entry
  # action. Mirrors Payroll::BulkOvertimeOverrider / BulkDeductionWaiver: no
  # separate summary audit log — each cleared entry already has its own.
  class BulkEntryReviewClearer
    Result = Struct.new(:success, :cleared, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(period:, actor:, entry_ids: nil)
      new(period: period, actor: actor, entry_ids: entry_ids).call
    end

    def initialize(period:, actor:, entry_ids:)
      @period    = period
      @actor     = actor
      @entry_ids = entry_ids
    end

    def call
      return err(I18n.t("payroll.needs_review.errors.permission")) unless @actor.can?(:complete_branch_review)
      return err(I18n.t("payroll.needs_review.errors.locked")) unless @period.editable?

      cleared = 0
      entries.find_each do |entry|
        result = EntryReviewClearer.call(entry: entry, actor: @actor)
        cleared += 1 if result.success?
      end

      Result.new(success: true, cleared: cleared)
    end

    private

    def entries
      scope = @period.payroll_entries.where(needs_review: true)
      scope = scope.where(id: @entry_ids) if @entry_ids.present?
      scope
    end

    def err(msg)
      Result.new(success: false, cleared: 0, error: msg)
    end
  end
end
