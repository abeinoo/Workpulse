module Payroll
  # Waives or restores the manual deductions of many entries in a period at once,
  # delegating each manual-deduction line item to Payroll::DeductionWaiver (so all
  # validation, audit, and recalculation rules are shared).
  #
  # action:
  #   "waive"   — waive every active manual deduction on the selected entries
  #   "restore" — restore every waived manual deduction on the selected entries
  #
  # A reason is required for both actions (it is recorded on each waiver/restore).
  # `applied` counts line items changed; `skipped` counts line items that the
  # single-item service declined (e.g. already in the target state).
  class BulkDeductionWaiver
    ACTIONS = %w[waive restore].freeze

    Result = Struct.new(:success, :applied, :skipped, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(period:, entry_ids:, action:, actor:, reason: nil)
      new(period: period, entry_ids: entry_ids, action: action, actor: actor, reason: reason).call
    end

    def initialize(period:, entry_ids:, action:, actor:, reason:)
      @period    = period
      @entry_ids = Array(entry_ids).map(&:to_i).uniq
      @action    = action.to_s
      @actor     = actor
      @reason    = reason.to_s.strip.presence
    end

    def call
      return err(I18n.t("payroll.deduction_waiver.errors.invalid_action")) unless ACTIONS.include?(@action)
      return err(I18n.t("payroll.deduction_waiver.errors.permission")) unless @actor.can?(:manage_payroll_deduction_waivers)
      return err(I18n.t("payroll.deduction_waiver.errors.locked")) unless @period.reviewable?
      return err(I18n.t("payroll.deduction_waiver.errors.none_selected")) if @entry_ids.empty?
      return err(I18n.t("payroll.deduction_waiver.errors.reason_required")) if @reason.blank?

      applied = 0
      skipped = 0

      line_items.find_each do |li|
        result = DeductionWaiver.call(line_item: li, action: @action, actor: @actor, reason: @reason)
        result.success? ? applied += 1 : skipped += 1
      end

      Result.new(success: true, applied: applied, skipped: skipped)
    end

    private

    # Approved manual deductions on the selected entries that are not already in the
    # target waiver state, so counts reflect real changes.
    def line_items
      PayrollLineItem
        .where(payroll_entry_id: target_entry_ids)
        .manual_deductions
        .where(review_status: "approved")
        .where(deduction_waived: @action == "restore")
    end

    def target_entry_ids
      @period.payroll_entries.where(id: @entry_ids).select(:id)
    end

    def err(msg)
      Result.new(success: false, applied: 0, skipped: 0, error: msg)
    end
  end
end
