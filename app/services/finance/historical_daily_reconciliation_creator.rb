module Finance
  # Creates a HISTORICAL DailyReconciliation for a business_date that was
  # never opened through the normal flow (e.g. staff forgot to start it, or
  # the branch simply didn't operate that day and it's being documented
  # afterward) — used by the "Create Daily Reconciliation" form when the
  # selected business_date is in the past.
  #
  # Deliberately creates NO live custody — no current_holder, no depositor —
  # since nothing was ever operationally tracked for this date. This also
  # means it never competes with idx_dr_one_open_per_branch /
  # idx_dr_one_waiting_per_branch (both scoped to state open /
  # waiting_for_opening): this always creates state "closed" directly, so
  # today's open session at the same branch, if any, is completely untouched.
  #
  # Seeds a zero-amount self-deposit TillHandover (with one TillHandoverAmount
  # per active payment method) purely so the EXISTING
  # Finance::SessionAmountsEditor / Finance::DayCloseEditor flow — both of
  # which require @dr.day_close_handover to be present — can be used
  # afterward to fill in the day's real totals, exactly like correcting any
  # other closed day. No custody/handover-acceptance workflow is involved.
  class HistoricalDailyReconciliationCreator
    include AuditLoggable

    Result = Struct.new(:ok, :reconciliation, :error, keyword_init: true) { def ok? = ok }

    def initialize(branch:, business_date:, actor:)
      @branch        = branch
      @business_date = business_date
      @actor         = actor
    end

    def call
      ActiveRecord::Base.transaction do
        reconciliation = DailyReconciliation.create!(
          branch:        @branch,
          business:      @branch.business,
          state:         "closed",
          opened_at:     Time.current,
          closed_at:     Time.current,
          business_date: @business_date
        )

        reconciliation.create_till_session!

        handover = TillHandover.create!(
          daily_reconciliation: reconciliation,
          from_user:            @actor,
          self_deposit:         true,
          fresha_date:          @business_date,
          from_notes:           "Backfilled historical reconciliation — no live custody was tracked for this date."
        )

        PaymentMethod.for_business(@branch.business).active.find_each do |pm|
          handover.amounts.create!(
            payment_method:      pm,
            payment_method_name: pm.display_name,
            collected_amount:    0,
            refund_amount:       0,
            kind:                "operational"
          )
        end

        Finance::TillHandoverCreator.sync_session_amounts!(reconciliation, handover)
        Finance::EmployeeReconciliationSummarizer.new(reconciliation).persist!

        log_audit(actor: @actor, auditable: reconciliation, action: "create_historical",
                  metadata: { branch_id: @branch.id, business_date: @business_date.to_s })

        Result.new(ok: true, reconciliation: reconciliation)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
