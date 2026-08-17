require "rails_helper"

# Query-count regression guard for the Daily Reconciliation index page.
#
# The first performance pass found that several DailyReconciliation
# aggregate methods (total_deposited, expected_cash_deposit,
# total_remaining_balance, total_matched_amount, bank_reconciliation_status,
# bank_statement_imported?, etc.) chained a scope directly onto an
# already-preloaded association, which always re-issues a SQL query
# regardless of preloading — defeating the index page's batching and
# growing the query count roughly linearly with the number of rendered
# reconciliations. This spec builds an increasingly large, realistic
# dataset (deposits, session amounts, bank statement matches, remaining
# balances, POS/Sales transactions, a day-close handover) and asserts the
# index page's query count stays flat as the number of DRs grows — not
# proportional to N.
RSpec.describe "Daily Reconciliation index — query count scaling", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:card_pm)  { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true, include_in_pos_verification: true) }

  let(:actor) do
    perms = %w[view_daily_reconciliation view_deposit_verification close_till_session
               create_till_deposit verify_deposits manual_match_deposits
               review_daily_reconciliation verify_daily_reconciliation
               view_all_employee_reconciliation_summary view_sales_transactions_verification
               view_pos_import manage_pos_import]
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  before { sign_in actor }

  # Builds `count` fully-populated DailyReconciliations on consecutive
  # business_dates starting at `start_business_date` (default: ending at
  # Date.current) — so callers can seed a second, older, non-overlapping
  # batch (see the LIMIT test below) without colliding with the DB's
  # one-closed-DR-per-branch-per-date unique index.
  def seed_reconciliations(count, start_business_date: Date.current - (count - 1))
    sales_import = SalesImport.create!(business: business, imported_by: actor,
                                        file_name: "bench.csv", status: "imported")
    pos_import   = create(:pos_import, business: business, imported_by: actor)

    count.times do |i|
      business_date = start_business_date + i
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: business_date.to_time + 8.hours, closed_at: business_date.to_time + 22.hours,
        business_date: business_date
      )
      TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id)

      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                                 payment_method_name: cash_pm.name, collected_amount: 500, refund_amount: 20)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: card_pm,
                                 payment_method_name: card_pm.name, collected_amount: 300, refund_amount: 0)

      dep = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                                 amount: (i.even? ? 480 : 300), deposited_at: business_date.to_time + 14.hours)

      # Bank statement + match for roughly a third of DRs — exercises the
      # bank_reconciliation_status matching logic, not just the empty path.
      if (i % 3).zero?
        stmt = create(:bank_statement, business: business, branch: branch,
                       statement_from: business_date, statement_to: business_date)
        txn = BankStatementTransaction.create!(bank_statement: stmt, business: business,
                                                transaction_date: business_date, amount: dep.amount,
                                                raw_data: {}, status: "unexpected")
        DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: txn, matched_by: actor)
        txn.update!(status: "verified")
      end

      # An open shortfall for roughly a fifth of DRs — exercises
      # total_remaining_balance / the Outstanding filter.
      if (i % 5).zero?
        RemainingDepositBalance.create!(
          daily_reconciliation: dr, till_deposit: dep, responsible_user: actor, created_by: actor,
          business: business, branch: branch, amount: 20, remaining_amount: 20, status: "open"
        )
      end

      # Day-close handover — gives the (deliberately un-batched, per the
      # existing code comments) Employee Reconciliation summarizer real
      # data to walk, and Sales/POS transactions to compare against.
      handover = TillHandover.create!(daily_reconciliation: dr, from_user: actor, self_deposit: true,
                                       created_at: business_date.to_time + 22.hours)
      TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm,
                                  payment_method_name: cash_pm.name, collected_amount: 500, refund_amount: 20)
      TillHandoverAmount.create!(till_handover: handover, payment_method: card_pm,
                                  payment_method_name: card_pm.name, collected_amount: 300, refund_amount: 0)

      SalesTransaction.create!(business: business, branch_id: branch.id, daily_reconciliation: dr,
                                sales_import: sales_import, cashier_name: actor.full_name,
                                branch_name: branch.name, payment_method_name: "Cash",
                                amount: 480, transaction_date: business_date, transaction_id: "S#{dr.id}-1")
      SalesTransaction.create!(business: business, branch_id: branch.id, daily_reconciliation: dr,
                                sales_import: sales_import, cashier_name: actor.full_name,
                                branch_name: branch.name, payment_method_name: "Card",
                                amount: 300, transaction_date: business_date, transaction_id: "S#{dr.id}-2")

      PosTransaction.create!(business: business, branch: branch, pos_import: pos_import,
                              transaction_id: "P#{dr.id}-1", amount: 300, payment_method: "Card",
                              status: "Success", transaction_date: business_date.to_time + 15.hours,
                              terminal_id: "TERM-1")
    end
  end

  def sql_query_count
    count = 0
    subscriber = ->(*, payload) {
      sql = payload[:sql].to_s
      count += 1 unless payload[:cached] || sql.start_with?("BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE")
    }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    count
  end

  it "keeps the index page's SQL query count roughly flat as the number of reconciliations grows" do
    seed_reconciliations(200)

    counts = [ 10, 50, 100, 200 ].index_with do |n|
      from_date = Date.current - (n - 1)
      # Warm run (routes/settings caches, etc.) so the measured run reflects
      # steady-state per-request cost, not one-time process warm-up.
      get finance_daily_reconciliations_path(from: from_date, to: Date.current)
      expect(response).to have_http_status(:ok)

      sql_query_count { get finance_daily_reconciliations_path(from: from_date, to: Date.current) }
    end

    counts.each { |n, c| puts "  #{n} DRs -> #{c} SQL queries" }

    # Not perfectly constant — a handful of per-page-but-per-row queries
    # (e.g. the deliberately un-batched EmployeeReconciliationSummarizer
    # walk, documented in the controller as intentionally scoped to only the
    # rendered set) still scale with the number of *displayed* rows. The
    # regression this guards against is the old behavior, where query count
    # scaled by a large constant factor (~10+ queries) per row. Asserting
    # sub-linear growth (well under the 20x row growth from 10 to 200 DRs)
    # catches that class of regression without being a brittle exact-count pin.
    expect(counts[200]).to be < (counts[10] * 3),
      "query count grew ~linearly with DR count (10 DRs: #{counts[10]}, 200 DRs: #{counts[200]}) " \
      "— an aggregate method likely regressed back to querying per-row instead of using preloaded data"
  end

  it "does not increase index page query count once the result set exceeds the page's own 200-row LIMIT" do
    seed_reconciliations(200)
    get finance_daily_reconciliations_path
    expect(response).to have_http_status(:ok)
    baseline = sql_query_count { get finance_daily_reconciliations_path }

    # 10 more, older, non-overlapping DRs — pushes the branch's total past
    # the index query's own .limit(200), so these never appear in the
    # rendered page (ordered by opened_at desc) but do sit in the DB.
    seed_reconciliations(10, start_business_date: Date.current - 219)

    get finance_daily_reconciliations_path
    expect(response).to have_http_status(:ok)
    with_more_rows_in_db = sql_query_count { get finance_daily_reconciliations_path }

    expect(with_more_rows_in_db).to eq(baseline)
  end
end
