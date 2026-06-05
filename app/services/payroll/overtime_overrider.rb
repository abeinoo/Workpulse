module Payroll
  # Applies a management overtime override to a single PayrollEntry.
  #
  # Attendance and overtime line items are never touched — this only adjusts how
  # much of the system-calculated overtime is payable. total_overtime is then
  # recomputed (via recalculate_totals!) so net_salary and every downstream
  # consumer reflect the decision.
  #
  # mode:
  #   "amount"  — approve a fixed payable amount (managers think in money)
  #   "minutes" — approve N overtime minutes (pay derived pro-rata)
  #   "restore" — remove the override, fall back to the system-calculated value
  #
  # A reason is required whenever the approved value differs from the calculated
  # one. Setting the approved value equal to the calculated one (or "restore") is
  # normalised to "no override" and needs no reason.
  class OvertimeOverrider
    MODES = %w[amount minutes restore].freeze

    Result = Struct.new(:success, :entry, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(entry:, mode:, actor:, value: nil, reason: nil)
      new(entry: entry, mode: mode, actor: actor, value: value, reason: reason).call
    end

    def initialize(entry:, mode:, actor:, value:, reason:)
      @entry  = entry
      @mode   = mode.to_s
      @actor  = actor
      @value  = value
      @reason = reason.to_s.strip.presence
    end

    def call
      return err("Invalid override mode '#{@mode}'") unless MODES.include?(@mode)
      return err(I18n.t("payroll.overtime_override.errors.permission")) unless @actor.can?(:manage_payroll_overrides)

      period = @entry.payroll_period
      return err(I18n.t("payroll.overtime_override.errors.locked")) unless period&.reviewable?

      attrs = resolved_attributes
      return attrs if attrs.is_a?(Result) # validation error short-circuit

      old_minutes = @entry.payable_overtime_minutes
      old_pay     = @entry.payable_overtime_pay

      ActiveRecord::Base.transaction do
        @entry.assign_attributes(attrs)
        @entry.save!
        @entry.recalculate_totals!
      end

      write_audit(old_minutes: old_minutes, old_pay: old_pay)
      Result.new(success: true, entry: @entry)
    rescue => e
      Rails.logger.error("[Payroll::OvertimeOverrider] entry=#{@entry.id} failed: #{e.message}")
      err(e.message)
    end

    private

    # Returns the attribute hash to assign, or a Result on validation failure.
    def resolved_attributes
      calc_minutes = @entry.calculated_overtime_minutes.to_i
      calc_pay     = @entry.calculated_overtime_pay.to_f

      return cleared_attributes if @mode == "restore"

      # Nothing to override when there is no calculated overtime. If a stale override
      # somehow remains, clear it; otherwise reject (can't inflate non-existent OT).
      if calc_minutes.zero? || calc_pay <= 0
        return @entry.overtime_overridden? ? cleared_attributes
                                           : err(I18n.t("payroll.overtime_override.errors.no_overtime"))
      end

      approved_minutes, approved_pay =
        case @mode
        when "amount"  then resolve_from_amount(calc_minutes, calc_pay)
        when "minutes" then resolve_from_minutes(calc_minutes, calc_pay)
        end

      # Approving the full calculated value is just a restore — no override, no reason.
      return cleared_attributes if approved_minutes == calc_minutes && (approved_pay - calc_pay).abs < 0.01

      return err(I18n.t("payroll.overtime_override.errors.reason_required")) if @reason.blank?

      {
        overtime_override_mode:    @mode,
        approved_overtime_minutes: approved_minutes,
        approved_overtime_pay:     approved_pay,
        overtime_override_reason:  @reason,
        overtime_overridden_by:    @actor,
        overtime_overridden_at:    Time.current,
        overtime_override_stale:   false
      }
    end

    # Amount mode: managers enter the payable money directly; minutes are derived
    # pro-rata for reporting/display only.
    def resolve_from_amount(calc_minutes, calc_pay)
      pay     = clamp(@value.to_f, 0.0, calc_pay).round(2)
      minutes = (calc_minutes * pay / calc_pay).round
      [ minutes, pay ]
    end

    # Minutes mode: managers approve N minutes; pay scales at the blended OT rate.
    def resolve_from_minutes(calc_minutes, calc_pay)
      minutes = clamp(@value.to_i, 0, calc_minutes)
      pay     = (calc_pay * minutes / calc_minutes).round(2)
      [ minutes, pay ]
    end

    def cleared_attributes
      {
        overtime_override_mode:    nil,
        approved_overtime_minutes: nil,
        approved_overtime_pay:     nil,
        overtime_override_reason:  nil,
        overtime_overridden_by:    nil,
        overtime_overridden_at:    nil,
        overtime_override_stale:   false
      }
    end

    def clamp(value, low, high)
      [ [ value, low ].max, high ].min
    end

    def write_audit(old_minutes:, old_pay:)
      PayrollAuditLog.create!(
        payroll_period: @entry.payroll_period,
        actor:          @actor,
        action_type:    "overtime_overridden",
        metadata:       {
          payroll_entry_id:   @entry.id,
          payroll_period_id:  @entry.payroll_period_id,
          employee_id:        @entry.user_id,
          mode:               @mode,
          calculated_minutes: @entry.calculated_overtime_minutes.to_i,
          calculated_pay:     @entry.calculated_overtime_pay.to_f,
          old_minutes:        old_minutes,
          new_minutes:        @entry.payable_overtime_minutes,
          old_pay:            old_pay,
          new_pay:            @entry.payable_overtime_pay,
          reason:             @reason
        }.to_json
      )
    rescue => e
      Rails.logger.error("[PayrollAuditLog] overtime_overridden write failed: #{e.message}")
    end

    def err(msg)
      Result.new(success: false, error: msg)
    end
  end
end
