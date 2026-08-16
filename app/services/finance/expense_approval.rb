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

    # draft | pending_approval | approved → cancelled
    #
    # draft/pending_approval: nothing has been posted yet, so cancellation is a
    # plain status flip. approved: the custody deduction already moved money
    # (see #post_balance_deduction), so it must be unwound — a reversing
    # FinancialSettlement (equal and opposite, original never touched) plus a
    # reversing CustodyTransaction that restores the account balance, mirroring
    # Inventory::GoodsReceiptVoider#reverse_settlements!.
    # Row-locked so a concurrent approve!/cancel! on the same expense can
    # never both succeed: whichever acquires the lock first commits, the
    # other reloads fresh state and cleanly fails the status check.
    def cancel!(reason:)
      result = nil
      ActiveRecord::Base.transaction do
        @expense.lock!

        unless @expense.status.in?(%w[draft pending_approval approved])
          result = Result.new(ok: false, expense: @expense,
                              error: I18n.t("finance.expenses.errors.cannot_cancel"))
          raise ActiveRecord::Rollback
        end

        prior_status = @expense.status
        reverse_balance_deduction! if prior_status == "approved"

        @expense.status              = "cancelled"
        @expense.cancelled_by        = @actor
        @expense.cancelled_at        = Time.current
        @expense.cancellation_reason = reason
        @expense.save!

        log_audit(actor: @actor, auditable: @expense, action: "cancel",
                  changes: { status: [ prior_status, "cancelled" ] },
                  metadata: { reason: reason }.compact)

        result = Result.new(ok: true, expense: @expense)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, expense: @expense, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def reverse_balance_deduction!
      originals = @expense.financial_settlements.to_a
      return if originals.empty?

      results = FinancialSettlementService.reverse_all(
        settleable: @expense, actor: @actor,
        notes: I18n.t("finance.expenses.cancellation_reversal_note", reference: @expense.reference_number)
      )
      failed = results.find { |r| !r.ok? }
      raise ActiveRecord::RecordInvalid, failed.settlement if failed

      originals.each do |settlement|
        next unless settlement.funding_source.is_a?(CustodyAccount)

        account = settlement.funding_source
        account.with_lock do
          account.custody_transactions.create!(
            business:   account.business,
            txn_type:   "expense_deduction_reversal",
            amount:     settlement.amount,
            expense:    @expense,
            created_by: @actor,
            notes:      I18n.t("finance.expenses.cancellation_reversal_note", reference: @expense.reference_number)
          )
          account.refresh_balance!
        end
      end
    end

    def post_balance_deduction
      return unless @expense.deduct_from_balance?

      creator = @expense.created_by
      return unless creator

      account = creator.custody_accounts.active.first
      return unless account

      settlement_result = FinancialSettlementService.create(
        settleable:     @expense,
        funding_source: account,
        amount:         @expense.amount,
        actor:          @actor,
        notes:          I18n.t("finance.custody.expense_deduction_note",
                               reference: @expense.reference_number)
      )
      raise ActiveRecord::RecordInvalid, settlement_result.settlement unless settlement_result.ok?

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

      log_audit(actor: @actor, auditable: @expense, action: "settle_from_custody",
                metadata: { custody_account_id: account.id, amount: @expense.amount })
    end

    def self_approval?
      return false if @actor.owner?

      Approvals::SelfApproval.by_requester?(approver: @actor, requester: @expense.created_by_id)
    end

    def self_approval_error
      Result.new(ok: false, expense: @expense, error: Approvals::SelfApproval.error_message)
    end

    # Row-locked for the same reason as #cancel! — closes the approve!-vs-
    # cancel! race from this side too.
    def transition(from:, to:, action:, metadata: {})
      result = nil
      ActiveRecord::Base.transaction do
        @expense.lock!

        unless @expense.status == from
          result = Result.new(ok: false, expense: @expense,
                              error: I18n.t("finance.expenses.errors.invalid_transition",
                                            default: "Invalid status transition."))
          raise ActiveRecord::Rollback
        end

        @expense.status = to
        yield if block_given?
        @expense.save!
        log_audit(actor: @actor, auditable: @expense, action: action,
                  changes: { status: [ from, to ] }, metadata: metadata)

        result = Result.new(ok: true, expense: @expense)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, expense: @expense, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
