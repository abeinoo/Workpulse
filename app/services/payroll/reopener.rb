module Payroll
  # Reopens a locked payroll period one step back through the lifecycle.
  #
  #   paid       → finalized                  (rolls back disbursement)
  #   finalized  → branch_review_completed    (reopens for further changes)
  #
  # Every reopen requires a non-blank reason and produces a PayrollAuditLog
  # entry so the action is traceable.
  #
  # Authorization is enforced at the policy layer (PayrollPeriodPolicy#reopen?)
  # — this service only performs the state change and writes the audit log.
  class Reopener
    REVERSE_TRANSITIONS = {
      "paid"      => "finalized",
      "finalized" => "branch_review_completed"
    }.freeze

    Result = Struct.new(:success, :period, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(period:, by:, reason:)
      new(period: period, by: by, reason: reason).call
    end

    def initialize(period:, by:, reason:)
      @period = period
      @by     = by
      @reason = reason.to_s.strip
    end

    def call
      return err("A reason is required to reopen a payroll period") if @reason.empty?

      to_status = REVERSE_TRANSITIONS[@period.status]
      return err("No reopen transition available from '#{@period.status}'") unless to_status

      from_status = @period.status

      ActiveRecord::Base.transaction do
        update_attrs = { status: to_status }
        # Clear forward-state metadata so the next finalize/pay is a fresh action.
        case to_status
        when "branch_review_completed"
          update_attrs[:finalized_at] = nil
          update_attrs[:finalized_by] = nil
        end
        @period.update!(update_attrs)

        PayrollAuditLog.create!(
          payroll_period: @period,
          actor:          @by,
          action_type:    :reopened,
          from_status:    from_status,
          to_status:      to_status,
          metadata:       { reason: @reason }.to_json
        )

        # Leaving "finalized" means payroll may change before the next
        # finalization, so its effects (the insurance Expense) are reverted now
        # (FS-D1) — through the Payroll-defined contract, inside this transaction.
        if to_status == "branch_review_completed"
          Payroll::FinalizationEffects.period_reopened(period: @period, actor: @by, reason: @reason)
        end
      end

      Result.new(success: true, period: @period)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    rescue StandardError => e
      err(e.message)
    end

    private

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
