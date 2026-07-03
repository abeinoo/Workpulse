class Finance::BankStatementTransactionsController < Finance::BaseController
  def show
    @transaction = find_transaction
    authorize @transaction
    @deposit            = @transaction.matched_till_deposit
    @statement          = @transaction.bank_statement
    @unmatched_deposits = unmatched_deposits_for_manual_matching if policy(@transaction).match?
    @audit_logs         = AuditLog.for_auditable(@transaction).includes(:actor).recent
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
      flash.now[:alert] = result.error
      @deposit            = @transaction.matched_till_deposit
      @statement          = @transaction.bank_statement
      @unmatched_deposits = unmatched_deposits_for_manual_matching
      render :show, status: :unprocessable_entity
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

  def unmatched_deposits_for_manual_matching
    statement = @transaction.bank_statement

    scope = TillDeposit
      .joins(:daily_reconciliation)
      .where(daily_reconciliations: { business_id: current_user.business_id })
      .where(daily_reconciliations: { business_date: statement.statement_from..statement.statement_to })
      .where(voided_at: nil)
      .where.missing(:bank_statement_transaction)
      .includes(:daily_reconciliation, :payment_method)
      .order(deposited_at: :desc)

    if statement.branch_id?
      scope = scope.where(daily_reconciliations: { branch_id: statement.branch_id })
    end

    scope
  end
end
