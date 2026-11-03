module Finance
  # Creates a DailyReconciliation for a PAST business_date that was never
  # opened through the normal flow (e.g. staff forgot to start it) — used by
  # the "Create Daily Reconciliation" form when the selected business_date is
  # in the past.
  #
  # The DR starts "open", exactly like today's, via
  # DailyReconciliation.create_for! (the only place a TillSession may be
  # created). It becomes "closed" only through the explicit closing workflow
  # (the day-close handover); its status is never derived from comparing
  # business_date with the current business day.
  #
  # Because it is open it competes with idx_dr_one_open_per_branch, and a
  # waiting_for_opening DR would shadow it in the cashier flow — so it is
  # refused while the branch has another open or waiting DR. The controller
  # checks the same thing first to redirect with a friendlier message; this
  # guard keeps console/job callers honest too.
  #
  # Concurrency: a second OPEN DR is impossible at the DB level
  # (idx_dr_one_open_per_branch → RecordNotUnique, mapped to a failed Result).
  # A waiting DR created concurrently by Finance::OpeningFloatLeaver is not
  # covered by any index, so both take DailyReconciliation.lock_branch_lifecycle!
  # and re-check under it.
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
        DailyReconciliation.lock_branch_lifecycle!(@branch.id)

        if DailyReconciliation.open_for(@branch) || DailyReconciliation.waiting_for(@branch)
          raise ArgumentError, I18n.t("finance.daily_reconciliations.errors.another_day_open_or_waiting")
        end

        reconciliation = DailyReconciliation.create_for!(branch: @branch, business_date: @business_date)

        log_audit(actor: @actor, auditable: reconciliation, action: "create_historical",
                  metadata: { branch_id: @branch.id, business_date: @business_date.to_s })

        Result.new(ok: true, reconciliation: reconciliation)
      end
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotUnique => e
      # Lost a race on idx_dr_unique_branch_business_date or
      # idx_dr_one_open_per_branch to a request outside the lifecycle lock
      # (e.g. today's create_for! path). Read from the error, not the DB: an
      # enclosing transaction, if any, is aborted at this point.
      key = e.message.include?("idx_dr_unique_branch_business_date") ? "dr_exists_for_date" : "another_day_open_or_waiting"
      Result.new(ok: false, error: I18n.t("finance.daily_reconciliations.errors.#{key}"))
    end
  end
end
