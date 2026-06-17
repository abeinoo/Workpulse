module Finance
  # Generates ONE pending expense from a recurring template for its current
  # next_run_on, then advances the schedule by one period. Never marks the
  # expense paid — it always lands in `pending_approval` for normal review.
  #
  # The generated expense is attributed to the template's creator (created_by)
  # and linked back via source_recurring_expense_id for full traceability. Shared
  # recurring templates reproduce their branch split through AllocationCalculator.
  #
  # `force: true` generates regardless of the due date (manual "generate now"),
  # still respecting active/ended.
  #
  # Duplicate protection is two-layered: the template row is locked
  # (SELECT FOR UPDATE) for the read-generate-advance, so a concurrent daily job
  # and a manual "Generate Now" serialize — the loser re-reads the advanced
  # schedule and skips. The partial unique index on
  # expenses(source_recurring_expense_id, expense_date) is the final backstop; a
  # lost race surfaces as RecordNotUnique and is treated as a no-op skip.
  class RecurringExpenseGenerator
    include AuditLoggable

    Result = Struct.new(:ok, :expense, :reason, keyword_init: true) { def ok? = ok }

    def initialize(recurring, on: nil, force: false)
      @recurring   = recurring
      @explicit_on = on
      @force       = force
    end

    def call
      result = nil
      @recurring.with_lock { result = attempt }
      result
    rescue ActiveRecord::RecordNotUnique
      skip(:already_generated)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, reason: e.record.errors.full_messages.to_sentence)
    end

    private

    # Runs inside the row lock + transaction opened by with_lock. Guard returns
    # make no writes, so the transaction simply commits as a no-op.
    def attempt
      return skip(:inactive) unless @recurring.active?

      on = @explicit_on || @recurring.next_run_on
      return skip(:ended)   if @recurring.ended_on?(on)
      return skip(:not_due) unless @force || @recurring.next_run_on <= Date.current

      expense = build_expense(on)
      expense.reference_number = NumberSequencer.new(@recurring.business, :expense).next_number
      expense.save!
      advance_schedule!(on)
      audit(expense, on)
      Result.new(ok: true, expense: expense)
    end

    def build_expense(on)
      expense = @recurring.business.expenses.build(
        branch:                   @recurring.branch,
        expense_category:         @recurring.expense_category,
        expense_type:             @recurring.expense_type,
        amount:                   @recurring.amount,
        expense_date:             on,
        status:                   "pending_approval",
        created_by:               @recurring.created_by,
        source_recurring_expense: @recurring
      )

      @recurring.recurring_expense_allocations.each do |alloc|
        expense.expense_allocations.build(branch_id: alloc.branch_id,
                                          allocation_percentage: alloc.allocation_percentage)
      end
      AllocationCalculator.new(expense, mode: "percentage").call if expense.expense_allocations.any?

      expense
    end

    # Advance next_run_on by one period from the scheduled date (keeps the cadence
    # aligned even when catching up late).
    def advance_schedule!(on)
      @recurring.update!(
        last_generated_on: on,
        next_run_on:       @recurring.next_occurrence_after(@recurring.next_run_on)
      )
    end

    # Attribute the generation to the template creator. Skip silently if the
    # template has no creator (AuditLog requires an actor).
    def audit(expense, on)
      return if @recurring.created_by.nil?

      log_audit(actor: @recurring.created_by, auditable: expense, action: "recurring_generate",
                metadata: { recurring_expense_id: @recurring.id, generated_on: on.to_s })
    end

    def skip(reason)
      Result.new(ok: false, reason: reason)
    end
  end
end
