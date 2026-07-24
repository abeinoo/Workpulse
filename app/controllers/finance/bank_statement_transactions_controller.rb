class Finance::BankStatementTransactionsController < Finance::BaseController
  def show
    @transaction       = find_transaction
    authorize @transaction
    @deposit           = @transaction.matched_till_deposit
    @statement         = @transaction.bank_statement
    @audit_logs        = AuditLog.for_auditable(@transaction).includes(:actor).recent
    @review_candidates = review_candidates if @transaction.needs_manual_review?
  end

  def manual_match_modal
    @transaction        = find_transaction
    authorize @transaction, :match?
    @unmatched_deposits = unmatched_deposits_for_manual_matching
  end

  def match
    @transaction = find_transaction
    authorize @transaction, :match?

    result = Finance::BankStatements::ManualMatcher.call(
      @transaction.id,
      till_deposit_id: params[:till_deposit_id].to_i,
      actor:           current_user,
      notes:           params[:match_notes].presence
    )

    if result.ok?
      redirect_to finance_bank_statement_transaction_path(@transaction),
                  notice: t("finance.bank_statement_transactions.matched")
    else
      redirect_to finance_bank_statement_transaction_path(@transaction),
                  alert: result.error
    end
  end

  def unmatch
    @transaction = find_transaction
    authorize @transaction, :unmatch?

    result = Finance::BankStatements::Unmatcher.call(
      @transaction.id,
      actor: current_user,
      notes: params[:unmatch_notes].presence
    )

    if result.ok?
      redirect_to finance_bank_statement_transaction_path(@transaction),
                  notice: t("finance.bank_statement_transactions.unmatched")
    else
      redirect_to finance_bank_statement_transaction_path(@transaction),
                  alert: result.error
    end
  end

  def ignore
    @transaction = find_transaction
    authorize @transaction, :ignore?

    result = Finance::BankStatements::Ignorer.call(
      @transaction.id,
      actor:  current_user,
      reason: params[:ignored_reason].presence
    )

    if result.ok?
      redirect_to finance_bank_statement_transaction_path(@transaction),
                  notice: t("finance.bank_statement_transactions.ignored")
    else
      redirect_to finance_bank_statement_transaction_path(@transaction),
                  alert: result.error
    end
  end

  private

  def find_transaction
    policy_scope(BankStatementTransaction).find(params[:id])
  end

  # The candidate snapshot recorded by MatchingEngine at the moment it flagged
  # this transaction for manual review — read from the audit trail rather
  # than re-querying live deposits, so the explanation reflects what the
  # engine actually saw even if a candidate has since been edited or voided.
  def review_candidates
    log = AuditLog.for_auditable(@transaction).where(action: "needs_manual_review").recent.first
    (log&.metadata || {})["candidates"] || []
  end

  def unmatched_deposits_for_manual_matching
    statement = @transaction.bank_statement

    scope = TillDeposit
      .joins(:daily_reconciliation)
      .where(daily_reconciliations: { business_id: current_user.business_id })
      .where(daily_reconciliations: { business_date: statement.statement_from..statement.statement_to })
      .where(voided_at: nil)
      .not_fully_matched
      .includes(:daily_reconciliation, :payment_method, :deposited_by, daily_reconciliation: :branch)
      .order(deposited_at: :desc)

    if statement.branch_id?
      scope = scope.where(daily_reconciliations: { branch_id: statement.branch_id })
    end

    scope
  end
end
