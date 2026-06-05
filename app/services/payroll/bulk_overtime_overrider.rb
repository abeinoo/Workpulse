module Payroll
  # Applies an overtime override to many entries in a period at once, delegating
  # each entry to Payroll::OvertimeOverrider (so all validation, clamping, audit,
  # and recalculation rules are shared).
  #
  # bulk_mode:
  #   "zero"          — set payable overtime to 0 (the primary workflow)
  #   "fixed_amount"  — set payable overtime to a fixed money amount
  #   "fixed_minutes" — set approved overtime to a fixed number of minutes
  #   "restore"       — remove overrides, fall back to calculated values
  #
  # Entries with no calculated overtime are skipped (nothing to override).
  class BulkOvertimeOverrider
    BULK_MODES = %w[zero fixed_amount fixed_minutes restore].freeze

    Result = Struct.new(:success, :applied, :skipped, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(period:, entry_ids:, bulk_mode:, actor:, value: nil, reason: nil)
      new(period: period, entry_ids: entry_ids, bulk_mode: bulk_mode,
          actor: actor, value: value, reason: reason).call
    end

    def initialize(period:, entry_ids:, bulk_mode:, actor:, value:, reason:)
      @period    = period
      @entry_ids = Array(entry_ids).map(&:to_i).uniq
      @bulk_mode = bulk_mode.to_s
      @actor     = actor
      @value     = value
      @reason    = reason
    end

    def call
      return err(I18n.t("payroll.overtime_override.errors.invalid_mode")) unless BULK_MODES.include?(@bulk_mode)
      return err(I18n.t("payroll.overtime_override.errors.permission")) unless @actor.can?(:manage_payroll_overrides)
      return err(I18n.t("payroll.overtime_override.errors.locked")) unless @period.reviewable?
      return err(I18n.t("payroll.overtime_override.errors.none_selected")) if @entry_ids.empty?

      mode, value = translate_mode
      applied = 0
      skipped = 0

      @period.payroll_entries.where(id: @entry_ids).find_each do |entry|
        result = OvertimeOverrider.call(
          entry: entry, mode: mode, value: value, reason: @reason, actor: @actor
        )
        result.success? ? applied += 1 : skipped += 1
      end

      Result.new(success: true, applied: applied, skipped: skipped)
    end

    private

    # Maps the bulk mode onto the single-entry OvertimeOverrider mode + value.
    def translate_mode
      case @bulk_mode
      when "zero"          then [ "amount",  0 ]
      when "fixed_amount"  then [ "amount",  @value ]
      when "fixed_minutes" then [ "minutes", @value ]
      when "restore"       then [ "restore", nil ]
      end
    end

    def err(msg)
      Result.new(success: false, applied: 0, skipped: 0, error: msg)
    end
  end
end
