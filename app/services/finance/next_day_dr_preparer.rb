module Finance
  # Prepares the next business day's DailyReconciliation after a cashier
  # closes the till with next_day_amounts (leaving a float for tomorrow).
  #
  # Creates a DR in `waiting_for_opening` state and links it back to the
  # self-deposit handover that carries the next_day amounts.  Idempotent:
  # if a DR already exists for the branch on the target date (in any state)
  # the call returns ok with the existing record and skips creation.
  #
  # Called exclusively from TillHandoverCreator#close_day! — never directly.
  class NextDayDrPreparer
    include AuditLoggable

    Result = Struct.new(:ok, :daily_reconciliation, :error, keyword_init: true) { def ok? = ok }

    def initialize(branch:, business:, actor:, source_handover:)
      @branch          = branch
      @business        = business
      @actor           = actor
      @source_handover = source_handover
    end

    def call
      @next_date = BusinessDay.current(context: @business) + 1

      existing = DailyReconciliation.find_by(branch: @branch, business_date: @next_date)
      return Result.new(ok: true, daily_reconciliation: existing) if existing

      ActiveRecord::Base.transaction do
        dr = DailyReconciliation.prepare_for_next_day!(
          branch:          @branch,
          business_date:   @next_date,
          source_handover: @source_handover
        )

        log_audit(
          actor:     @actor,
          auditable: @source_handover.daily_reconciliation,
          action:    "opening_float_prepared",
          metadata:  {
            next_dr_id:         dr.id,
            branch_id:          @branch.id,
            source_handover_id: @source_handover.id
          }
        )

        Result.new(ok: true, daily_reconciliation: dr)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotUnique
      # Race condition: another process created the same DR between our check and
      # insert. Reuse @next_date (computed once at call start) to avoid a
      # BusinessDay.current re-evaluation that could return a different date if
      # the business day rolled over between the two evaluations.
      existing = DailyReconciliation.find_by(branch: @branch, business_date: @next_date)
      Result.new(ok: true, daily_reconciliation: existing)
    end
  end
end
