class Finance::DepositVerificationsController < Finance::BaseController
  DEFAULT_PER_PAGE = 30

  def index
    authorize :deposit_verification, :index?

    @filter_branches = assignable_branches
    @branch_ids      = accessible_branch_ids

    # Summary stats (always business/scope-wide, ignoring pagination)
    @stats = build_stats

    # Tabbed list
    @active_tab = params.fetch(:tab, "all")
    @page       = [ params.fetch(:page, 1).to_i, 1 ].max

    case @active_tab
    when "missing"
      load_missing_deposits
    when "ignored"
      load_ignored_deposits
    when "unexpected"
      load_unexpected_transactions
    when "needs_review"
      load_needs_review_transactions
    when "mismatches"
      load_mismatched_transactions
    else
      load_all_deposits
    end
  end

  private

  def accessible_branch_ids
    return nil if current_user.owner?

    scope_type = current_user.scope_for(:view_deposit_verification) || :default
    return nil if scope_type.to_s == "business"

    BranchScope.new(current_user).for_scope(scope_type)
  end

  def base_deposit_scope
    scope = TillDeposit
      .joins(:daily_reconciliation)
      .where(daily_reconciliations: { business_id: current_user.business_id })
      .where(voided_at: nil)

    if @branch_ids
      scope = scope.where(daily_reconciliations: { branch_id: @branch_ids })
    end

    if params[:branch_id].present?
      scope = scope.where(daily_reconciliations: { branch_id: params[:branch_id] })
    end

    if params[:from].present?
      scope = scope.where("till_deposits.deposited_at >= ?", params[:from].to_date.beginning_of_day)
    end

    if params[:to].present?
      scope = scope.where("till_deposits.deposited_at <= ?", params[:to].to_date.end_of_day)
    end

    scope
  end

  def base_transaction_scope
    # Lines of a deleted statement are kept for audit only, never listed.
    scope = BankStatementTransaction
              .for_business(current_user.business)
              .joins(:bank_statement)
              .where(bank_statements: { deleted_at: nil })

    if @branch_ids
      scope = scope.where(bank_statements: { branch_id: [ nil, *@branch_ids ] })
    end

    if params[:branch_id].present?
      scope = scope.where(bank_statements: { branch_id: params[:branch_id] })
    end

    if params[:from].present?
      scope = scope.where("bank_statement_transactions.transaction_date >= ?", params[:from])
    end

    if params[:to].present?
      scope = scope.where("bank_statement_transactions.transaction_date <= ?", params[:to])
    end

    scope
  end

  def build_stats
    txn_counts  = base_transaction_scope.group(:status).count
    total_txns  = txn_counts.values.sum
    verified    = txn_counts["verified"].to_i

    missing_count = missing_deposits_scope.count
    ignored_count = ignored_deposits_scope.count

    {
      total_imported:  total_txns,
      verified:        verified,
      missing:         missing_count,
      ignored:         ignored_count,
      unexpected:      txn_counts["unexpected"].to_i,
      amount_mismatch: txn_counts["amount_mismatch"].to_i,
      date_mismatch:   txn_counts["date_mismatch"].to_i,
      needs_review:    txn_counts["needs_manual_review"].to_i,
      rate:            total_txns.zero? ? 0 : (verified.to_f / total_txns * 100).round(1)
    }
  end

  def missing_deposits_scope
    # Deposits that fall within any imported bank statement's date range but
    # have no matching bank statement transaction. Deposits marked ignored are
    # deliberately excluded — they're no longer "unresolved missing", they
    # have their own "ignored" tab/status.
    covered_dates = BankStatement
                      .where(business: current_user.business)
                      .active
                      .where(status: "completed")
                      .pluck(:statement_from, :statement_to)

    return TillDeposit.none if covered_dates.empty?

    base = base_deposit_scope.where.missing(:deposit_matches).where(ignored_at: nil)

    # Filter to deposits within at least one statement's date range
    date_conditions = covered_dates.map { |from, to| "(DATE(till_deposits.deposited_at) BETWEEN ? AND ?)" }
                                   .join(" OR ")
    flat_dates = covered_dates.flatten

    base.where(date_conditions, *flat_dates)
  end

  def ignored_deposits_scope
    base_deposit_scope.where.not(ignored_at: nil)
  end

  def load_all_deposits
    deposits = base_deposit_scope
                 .left_joins(:bank_statement_transactions)
                 .distinct
                 .includes(:payment_method, :deposited_by,
                           { bank_statement_transactions: :bank_statement }, :bank_disputes,
                           daily_reconciliation: :branch)
                 .order(deposited_at: :desc)

    @total_count = deposits.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @deposits    = deposits.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)
  end

  def load_missing_deposits
    deposits = missing_deposits_scope
                 .includes(:payment_method, :deposited_by, :bank_disputes,
                           daily_reconciliation: :branch)
                 .order(deposited_at: :desc)

    @total_count = deposits.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @deposits    = deposits.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)
  end

  def load_ignored_deposits
    deposits = ignored_deposits_scope
                 .includes(:payment_method, :deposited_by, :ignored_by, :bank_disputes,
                           daily_reconciliation: :branch)
                 .order(ignored_at: :desc)

    @total_count = deposits.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @deposits    = deposits.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)
  end

  def load_unexpected_transactions
    transactions = base_transaction_scope
                     .unexpected
                     .includes(:bank_statement)
                     .ordered

    @total_count  = transactions.count
    @total_pages  = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @transactions = transactions.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)
  end

  def load_needs_review_transactions
    transactions = base_transaction_scope
                     .where(status: "needs_manual_review")
                     .includes(:bank_statement)
                     .ordered

    @total_count  = transactions.count
    @total_pages  = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @transactions = transactions.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)
  end

  def load_mismatched_transactions
    transactions = base_transaction_scope
                     .mismatched
                     .includes(:till_deposits, :bank_statement)
                     .ordered

    @total_count  = transactions.count
    @total_pages  = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @transactions = transactions.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)
  end
end
