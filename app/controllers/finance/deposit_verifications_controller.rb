class Finance::DepositVerificationsController < Finance::BaseController
  DEFAULT_PER_PAGE = 30

  # Bank-transaction tabs that offer bulk ignore, and the statuses each lists.
  BULK_IGNORE_TABS = {
    "unexpected"   => %w[unexpected],
    "needs_review" => %w[needs_manual_review],
    "mismatches"   => %w[amount_mismatch date_mismatch]
  }.freeze

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

    load_bulk_ignore_selection
  end

  # POST /finance/deposit_verifications/bulk_ignore
  #
  # Either the ids of rows ticked on the page (each must be visible to this
  # user through the policy scope), or selection=all_matching: every eligible
  # transaction matching the posted tab/branch/date filters, re-resolved here
  # and refused when the count no longer equals the one the user confirmed
  # (expected_count). Finance::BankStatements::BulkIgnorer re-checks every
  # transaction under lock and ignores all of them or none.
  def bulk_ignore
    authorize BankStatementTransaction, :bulk_ignore?
    @branch_ids = accessible_branch_ids
    tab = params[:tab].to_s
    return redirect_to(bulk_ignore_return_path, alert: t("finance.bank_statements.errors.bulk_ignore_none_selected")) unless BULK_IGNORE_TABS.key?(tab)

    ids = if params[:selection] == "all_matching"
      scope = bulk_ignore_scope(tab)
      count = scope.count
      unless count == params[:expected_count].to_i
        return redirect_to(bulk_ignore_return_path,
                           alert: t("finance.bank_statements.errors.bulk_ignore_selection_changed", count: count))
      end
      scope.limit(Finance::BankStatements::BulkIgnorer::MAX_TRANSACTIONS + 1).pluck(:id)
    else
      requested = Array(params[:transaction_ids]).filter_map { |id| Integer(id, exception: false) }.uniq
      visible   = policy_scope(BankStatementTransaction).where(id: requested).count
      return redirect_to(bulk_ignore_return_path, alert: t("finance.bank_statements.errors.bulk_ignore_unavailable")) if visible != requested.size

      requested
    end

    result = Finance::BankStatements::BulkIgnorer.new(transaction_ids: ids, actor: current_user,
                                                      reason: params[:reason]).call
    if result.ok?
      redirect_to bulk_ignore_return_path, notice: t("finance.deposit_verifications.bulk_ignore.done", count: result.ignored_count)
    else
      redirect_to bulk_ignore_return_path, alert: result.error
    end
  end

  private

  # Selectable rows on the current page (one query) and the eligible total
  # across every page of the current filters — only on bank-transaction tabs,
  # only for users who may bulk ignore.
  def load_bulk_ignore_selection
    return unless BULK_IGNORE_TABS.key?(@active_tab) && policy(BankStatementTransaction).bulk_ignore?

    eligible = bulk_ignore_scope(@active_tab)
    @bulk_ignore_eligible_ids   = eligible.where(id: @transactions.map(&:id)).pluck(:id).to_set
    @bulk_ignore_eligible_total = eligible.count
  end

  def bulk_ignore_scope(tab)
    Finance::BankStatements::BulkIgnorer.eligible(base_transaction_scope).where(status: BULK_IGNORE_TABS.fetch(tab))
  end

  # Back to the same tab and filters (page 1: ignored rows leave the list).
  def bulk_ignore_return_path
    finance_deposit_verifications_path(params.permit(:tab, :branch_id, :from, :to).to_h.compact_blank)
  end

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
