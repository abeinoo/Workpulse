require "rails_helper"

RSpec.describe "Daily Reconciliations — accountant workspace", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) do
    user_with("view_daily_reconciliation", "view_deposit_verification", "close_till_session",
              "create_till_deposit", "verify_deposits", "manual_match_deposits",
              "verify_daily_reconciliation", "view_session_totals",
              "view_reconciliation_workflow", "view_reconciliation_insights")
  end

  before { sign_in actor }

  def make_dr(depositor: actor, business_date: Date.current)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: business_date.to_time + 10.hours, closed_at: business_date.to_time + 23.hours,
      business_date: business_date
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: depositor.id)
    dr
  end

  def collect_cash!(dr, amount)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                              payment_method_name: cash_pm.name, collected_amount: amount, refund_amount: 0)
  end

  def deposit(dr, amount:, depositor: actor)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: depositor,
                        amount: amount, deposited_at: dr.business_date.to_time + 14.hours)
  end

  describe "workflow dashboard" do
    it "shows the four reorganized dashboard sections with correct pipeline/financial figures" do
      dr_waiting = make_dr(business_date: Date.new(2026, 7, 10))
      collect_cash!(dr_waiting, 400)

      dr_completed = make_dr(business_date: Date.new(2026, 7, 11))
      collect_cash!(dr_completed, 600)
      dep = deposit(dr_completed, amount: 600)
      stmt = create(:bank_statement, business: business, branch: branch,
                    statement_from: Date.new(2026, 7, 11), statement_to: Date.new(2026, 7, 11))
      txn = BankStatementTransaction.create!(bank_statement: stmt, business: business,
                                             transaction_date: Date.new(2026, 7, 11), amount: 600,
                                             raw_data: {}, status: "unexpected")
      DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: txn, matched_by: actor)
      txn.update!(status: "verified")

      get finance_daily_reconciliations_path

      body = response.body
      expect(body).to include(t_ws("section_workflow_title"))
      expect(body).to include(t_ws("section_exceptions_title"))
      expect(body).to include(t_ws("section_financial_title"))
      expect(body).to include(t_ws("section_operational_title"))
      # Financial Summary — deposited + matched totals for dr_completed.
      expect(body).to include(format_currency_like(600))
    end

    it "clicking a dashboard card filters the list to that status" do
      make_dr(business_date: Date.new(2026, 7, 10)).tap { |dr| collect_cash!(dr, 400) }
      dr_completed = make_dr(business_date: Date.new(2026, 7, 11))
      collect_cash!(dr_completed, 600)
      dep = deposit(dr_completed, amount: 600)
      stmt = create(:bank_statement, business: business, branch: branch,
                    statement_from: Date.new(2026, 7, 11), statement_to: Date.new(2026, 7, 11))
      txn = BankStatementTransaction.create!(bank_statement: stmt, business: business,
                                             transaction_date: Date.new(2026, 7, 11), amount: 600,
                                             raw_data: {}, status: "unexpected")
      DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: txn, matched_by: actor)
      txn.update!(status: "verified")

      get finance_daily_reconciliations_path(verification_status: "completed")

      expect(response.body).to include(finance_daily_reconciliation_path(dr_completed))
    end
  end

  describe "dashboard statistics recompute per selected depositor" do
    it "shows overall stats across all depositors when none is selected" do
      other = user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit")

      dr_actor = make_dr(depositor: actor, business_date: Date.new(2026, 7, 10))
      collect_cash!(dr_actor, 400)

      dr_other = make_dr(depositor: other, business_date: Date.new(2026, 7, 11))
      collect_cash!(dr_other, 600)

      get finance_daily_reconciliations_path

      doc = Nokogiri::HTML(response.body)
      value = doc.css(".stat-card__value").find { |el| el.text.strip == "2" }
      expect(value).to be_present # both waiting_for_deposit DRs counted together
    end

    it "recalculates every dashboard card, the amount summary, and outstanding to only the selected depositor's DRs" do
      other = user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit")

      dr_actor = make_dr(depositor: actor, business_date: Date.new(2026, 7, 10))
      collect_cash!(dr_actor, 400)
      dep_actor = deposit(dr_actor, amount: 300, depositor: actor)
      RemainingDepositBalance.create!(
        daily_reconciliation: dr_actor, till_deposit: dep_actor, responsible_user: actor, created_by: actor,
        business: business, branch: branch, amount: 100, remaining_amount: 100, status: "open"
      )

      dr_other = make_dr(depositor: other, business_date: Date.new(2026, 7, 11))
      collect_cash!(dr_other, 900)

      get finance_daily_reconciliations_path(depositor_id: actor.id)

      body = response.body
      # Waiting for Deposit card must show 0 for actor's own DR (they already
      # deposited something) and must NOT reflect dr_other (other depositor).
      expect(body).to include(finance_daily_reconciliation_path(dr_actor))
      expect(body).not_to include(finance_daily_reconciliation_path(dr_other))

      # Amount summary — expected/deposited/outstanding must be actor-only.
      expect(response.body).to include(format_currency_like(400)) # expected
      expect(response.body).to include(format_currency_like(300)) # deposited
      expect(response.body).to include(format_currency_like(100)) # outstanding
      expect(response.body).not_to include(format_currency_like(900)) # dr_other's expected, must not leak in
    end

    it "updates counts automatically when switching from one depositor to another" do
      other = user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit")

      dr_actor = make_dr(depositor: actor, business_date: Date.new(2026, 7, 10))
      collect_cash!(dr_actor, 400)

      dr_other = make_dr(depositor: other, business_date: Date.new(2026, 7, 11))
      collect_cash!(dr_other, 600)
      dr_other_2 = make_dr(depositor: other, business_date: Date.new(2026, 7, 12))
      collect_cash!(dr_other_2, 300)

      get finance_daily_reconciliations_path(depositor_id: actor.id)
      expect(response.body).to include(finance_daily_reconciliation_path(dr_actor))
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_other))
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_other_2))

      get finance_daily_reconciliations_path(depositor_id: other.id)
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_actor))
      expect(response.body).to include(finance_daily_reconciliation_path(dr_other))
      expect(response.body).to include(finance_daily_reconciliation_path(dr_other_2))
    end
  end

  describe "Deposited By filter (no dedicated select on the index page — driven by the Top Depositors card / depositor_id param directly)" do
    it "tallies deposit counts per depositor (shown via the Top Depositors card) and filters when a depositor_id is applied" do
      other = user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit")

      dr_a = make_dr(depositor: actor, business_date: Date.new(2026, 7, 10))
      collect_cash!(dr_a, 100)
      deposit(dr_a, amount: 100, depositor: actor)

      dr_b = make_dr(depositor: other, business_date: Date.new(2026, 7, 11))
      collect_cash!(dr_b, 200)
      deposit(dr_b, amount: 200, depositor: other)

      get finance_daily_reconciliations_path
      expect(response.body).to include(t_ws("depositor_count", name: actor.full_name, count: 1))
      expect(response.body).to include(t_ws("depositor_count", name: other.full_name, count: 1))

      get finance_daily_reconciliations_path(depositor_id: actor.id)
      expect(response.body).to include(finance_daily_reconciliation_path(dr_a))
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_b))
    end

    it "combines with the branch/date/bank-status filters already applied" do
      other = user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit")
      dr_a = make_dr(depositor: actor, business_date: Date.new(2026, 7, 10))
      collect_cash!(dr_a, 100)
      deposit(dr_a, amount: 100, depositor: actor)

      dr_b = make_dr(depositor: actor, business_date: Date.new(2026, 7, 12))
      collect_cash!(dr_b, 100)
      deposit(dr_b, amount: 100, depositor: actor)
      _ = other

      get finance_daily_reconciliations_path(depositor_id: actor.id, from: "2026-07-10", to: "2026-07-10")

      expect(response.body).to include(finance_daily_reconciliation_path(dr_a))
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_b))
    end
  end

  describe "Bank Imported / Outstanding Exists filters" do
    it "filters to only DRs with an imported covering statement" do
      dr_no_stmt = make_dr(business_date: Date.new(2026, 7, 10))
      collect_cash!(dr_no_stmt, 100)
      deposit(dr_no_stmt, amount: 100)

      dr_with_stmt = make_dr(business_date: Date.new(2026, 7, 11))
      collect_cash!(dr_with_stmt, 100)
      deposit(dr_with_stmt, amount: 100)
      create(:bank_statement, business: business, branch: branch,
             statement_from: Date.new(2026, 7, 11), statement_to: Date.new(2026, 7, 11))

      get finance_daily_reconciliations_path(bank_imported: "1")

      expect(response.body).to include(finance_daily_reconciliation_path(dr_with_stmt))
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_no_stmt))
    end

    it "filters to only DRs with an outstanding balance" do
      dr_clean = make_dr(business_date: Date.new(2026, 7, 10))
      collect_cash!(dr_clean, 100)
      deposit(dr_clean, amount: 100)

      dr_short = make_dr(business_date: Date.new(2026, 7, 11))
      collect_cash!(dr_short, 100)
      dep = deposit(dr_short, amount: 60)
      RemainingDepositBalance.create!(
        daily_reconciliation: dr_short, till_deposit: dep, responsible_user: actor, created_by: actor,
        business: business, branch: branch, amount: 40, remaining_amount: 40, status: "open"
      )

      get finance_daily_reconciliations_path(outstanding_exists: "1")

      expect(response.body).to include(finance_daily_reconciliation_path(dr_short))
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_clean))
    end
  end

  describe "empty states" do
    it "shows a status-specific message when a bank-status filter yields no rows" do
      make_dr(business_date: Date.new(2026, 7, 10))

      get finance_daily_reconciliations_path(verification_status: "needs_review")

      expect(response.body).to include(t_ws("empty_states.needs_review"))
    end
  end

  describe "export" do
    it "returns a CSV with a row per reconciliation" do
      dr = make_dr(business_date: Date.new(2026, 7, 5))
      collect_cash!(dr, 250)
      deposit(dr, amount: 250)

      get export_finance_daily_reconciliations_path(ids: [ dr.id ])

      expect(response.content_type).to include("text/csv")
      expect(response.body).to include(branch.name)
    end
  end

  def t_ws(key, **args) = I18n.t("finance.daily_reconciliations.index.workspace.#{key}", **args)
  def format_currency_like(amount) = ApplicationController.helpers.number_with_precision(amount, precision: 2, delimiter: ",")
end
