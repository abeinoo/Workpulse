module Finance
  # Handles expense lifecycle transitions: submit → approve, plus reject.
  #
  # On approval the service automatically posts a negative expense_deduction
  # transaction against the creator's balance account (if one exists), updating
  # their running balance. Negative balances are intentional: a negative balance
  # means the company owes the employee money.
  #
  # Self-approval is blocked (creators may not approve their own expenses), with
  # the business-owner exception for sole-proprietor setups.
  class ExpenseApproval
    include AuditLoggable

    Result = Struct.new(:ok, :expense, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(expense, actor:)
      @expense = expense
      @actor   = actor
    end

    # draft → pending_approval
    def submit!
      transition(from: "draft", to: "pending_approval", action: "submit")
    end

    # pending_approval → approved
    # Auto-posts an expense_deduction on the creator's balance account.
    def approve!
      return self_approval_error if self_approval?

      transition(from: "pending_approval", to: "approved", action: "approve") do
        @expense.approved_by = @actor
        @expense.approved_at = Time.current
        post_balance_deduction
      end
    end

    # pending_approval → rejected
    def reject!(reason:)
      return self_approval_error if self_approval?

      transition(from: "pending_approval", to: "rejected", action: "reject",
                 metadata: { reason: reason }) do
        @expense.rejected_at      = Time.current
        @expense.rejection_reason = reason
      end
    end

    private

    def post_balance_deduction
      return unless @expense.deduct_from_balance?

      creator = @expense.created_by
      return unless creator

      account = creator.custody_accounts.active.first
      return unless account

      account.custody_transactions.create!(
        business:   account.business,
        txn_type:   "expense_deduction",
        amount:     -@expense.amount,
        expense:    @expense,
        created_by: @actor,
        notes:      I18n.t("finance.custody.expense_deduction_note",
                           reference: @expense.reference_number)
      )
      account.refresh_balance!
    end

    def self_approval?
      return false if @actor.owner?

      Approvals::SelfApproval.by_requester?(approver: @actor, requester: @expense.created_by_id)
    end

    def self_approval_error
      Result.new(ok: false, expense: @expense, error: Approvals::SelfApproval.error_message)
    end

    def transition(from:, to:, action:, metadata: {})
      unless @expense.status == from
        return Result.new(ok: false, expense: @expense,
                          error: I18n.t("finance.expenses.errors.invalid_transition",
                                        default: "Invalid status transition."))
      end

      ActiveRecord::Base.transaction do
        @expense.status = to
        yield if block_given?
        @expense.save!
        log_audit(actor: @actor, auditable: @expense, action: action,
                  changes: { status: [ from, to ] }, metadata: metadata)
      end
      Result.new(ok: true, expense: @expense)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, expense: @expense, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
