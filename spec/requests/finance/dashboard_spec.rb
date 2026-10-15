require "rails_helper"

RSpec.describe "Finance::Dashboard", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # Every dashboard-access spec below needs view_finance_dashboard just to
  # reach the page — mix it in alongside whatever permission the example is
  # actually testing.
  def user_with_dashboard(*perms)
    user_with("view_finance_dashboard", *perms)
  end

  describe "GET /finance (executive dashboard)" do
    it "renders successfully for an owner with no data" do
      sign_in owner
      get finance_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.revenue"))
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.net_profit"))
    end

    it "hides capability-gated widgets when the backing data model doesn't exist" do
      sign_in owner
      get finance_root_path
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.supplier_payables"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.cash_balance"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.bank_balance"))
    end

    it "renders with expenses, custody, and a date filter applied" do
      category = create(:expense_category, business: business)
      create(:expense, business: business, branch: branch, expense_category: category,
             status: "approved", amount: 500, expense_date: Date.current)
      create(:custody_account, business: business, branch: branch, user: owner)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)
    end

    it "redirects a user without any finance permission" do
      outsider = create(:user, business: business)
      sign_in outsider
      get finance_root_path
      expect(response).to redirect_to(root_path)
    end

    it "redirects a user who has other Finance permissions but not view_finance_dashboard" do
      viewer = user_with("view_expenses", "view_expense_reports", "view_daily_reconciliation")
      sign_in viewer
      get finance_root_path
      expect(response).to redirect_to(root_path)
    end

    it "hides revenue, net profit, margin, and branch profitability from a user without view_expense_reports" do
      viewer = user_with_dashboard("view_expenses")
      sign_in viewer
      get finance_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.revenue"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.net_profit"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.profit_margin"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.by_branch_revenue"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.profitability"))
      # Expenses (not report-gated) should still be visible.
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.expenses"))
    end

    it "shows revenue, net profit, and branch profitability to a user with view_expense_reports" do
      viewer = user_with_dashboard("view_expenses", "view_expense_reports")
      sign_in viewer
      get finance_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.revenue"))
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.net_profit"))
    end

    it "computes the Revenue KPI from a verified Daily Reconciliation's session amounts, not BranchRevenue" do
      cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "verified",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
        verified_at: Date.current.to_time, verified_by_id: owner.id
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 4200, refund_amount: 200)
      # A manual BranchRevenue row must NOT be picked up (it's no longer a revenue source).
      create(:branch_revenue, business: business, branch: branch, period_month: Date.current.beginning_of_month, amount: 99_999)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response.body).to include("4,000.00")
      expect(response.body).not_to include("99,999.00")
    end

    it "shows zero revenue when there is no verified Daily Reconciliation for the period, not an error" do
      cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 5000, refund_amount: 0)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("5,000.00")
    end

    it "includes the real revenue figure in the trend chart's monthly data, not a flat zero line" do
      # Regression test for a Time-vs-Date Hash#eql? bug that silently zeroed
      # out every point on the trend chart (see Finance::Reports::VerifiedRevenue#by_month).
      cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "verified",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
        verified_at: Date.current.to_time, verified_by_id: owner.id
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 6000, refund_amount: 0)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)

      raw = response.body[/data-trend-chart-revenue-value="(.*?)"\s/, 1]
      revenue_series = JSON.parse(CGI.unescapeHTML(raw))
      expect(revenue_series.last.to_f).to eq(6000)
      expect(revenue_series.sum(&:to_f)).to eq(6000) # every other month genuinely has no data
    end
  end

  describe "revenue widget empty states" do
    it "shows the revenue-specific empty state (not a blank card, not the generic no-data message) for Revenue by Branch and Branch Profitability when no verified DR exists" do
      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)

      # Titles/full-report links stay — only the chart area is replaced.
      expect(response.body).to include(I18n.t("finance.dashboard.by_branch_revenue"))
      expect(response.body).to include(I18n.t("finance.dashboard.profitability"))
      expect(response.body.scan(I18n.t("finance.dashboard.no_revenue.title")).size).to eq(2)
      expect(response.body).to include(I18n.t("finance.dashboard.no_revenue.text"))
    end

    it "renders the actual charts once a verified DR exists for the period, not the empty state" do
      cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "verified",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
        verified_at: Date.current.to_time, verified_by_id: owner.id
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 3000, refund_amount: 0)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("finance.dashboard.no_revenue.title"))
      expect(response.body).to include('data-chart-type-value="doughnut"')
      expect(response.body).to include("data-sortable-bars-target=\"canvas\"")
    end

    it "does not show the revenue empty state to a user without view_expense_reports (the whole card is hidden instead)" do
      viewer = user_with_dashboard("view_expenses")
      sign_in viewer
      get finance_root_path
      expect(response.body).not_to include(I18n.t("finance.dashboard.no_revenue.title"))
    end
  end

  describe "recent activity — human-readable labels, never raw Rails class/action names" do
    def expense_record
      category = create(:expense_category, business: business)
      create(:expense, :approved, business: business, branch: branch, expense_category: category, amount: 500)
    end

    it "shows a translated business-facing label instead of the raw class/action name" do
      AuditLog.create!(actor: owner, business: business, auditable: expense_record, action: "approve")

      sign_in owner
      get finance_root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.dashboard.recent_activity.expense_approve"))
      # The raw "#{class} #{action}" fallback format is "Expense approve" (no
      # trailing "d") — check the exact boundary so "Expense approved" (the
      # correct translated text, which happens to start with the same
      # substring) doesn't produce a false failure here.
      expect(response.body).not_to match(/Expense approve[^d]/)
    end

    it "falls back to a safe generic label for an unmapped action, never the raw action name" do
      AuditLog.create!(actor: owner, business: business, auditable: expense_record, action: "some_future_action")

      sign_in owner
      get finance_root_path

      expect(response.body).to include(I18n.t("finance.dashboard.recent_activity.generic_fallback"))
      expect(response.body).not_to include("some_future_action")
    end

    it "still shows the actor's name and a relative timestamp" do
      AuditLog.create!(actor: owner, business: business, auditable: expense_record, action: "approve")

      sign_in owner
      get finance_root_path

      expect(response.body).to include(owner.full_name)
      expect(response.body).to match(/less than a minute|\d+ (second|minute|hour)s? ago/)
    end
  end

  describe "GET /finance/dashboard/export_pdf" do
    it "streams a PDF for an owner" do
      allow(Finance::Dashboard::PdfRenderer).to receive(:render).and_return("%PDF-1.4 stub")

      sign_in owner
      get finance_dashboard_export_pdf_path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
    end

    it "redirects a user who lacks view_finance_dashboard, even with other finance permissions" do
      viewer = user_with("view_expenses", "view_expense_reports")
      sign_in viewer
      get finance_dashboard_export_pdf_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "view_finance_dashboard is independent from every other Finance:: permission" do
    it "does not grant access to Expenses" do
      viewer = user_with_dashboard
      sign_in viewer
      get finance_expenses_path
      expect(response).to redirect_to(root_path)
    end

    it "does not grant access to Custody" do
      viewer = user_with_dashboard
      sign_in viewer
      get finance_custody_accounts_path
      expect(response).to redirect_to(root_path)
    end

    it "does not grant access to Reports" do
      viewer = user_with_dashboard
      sign_in viewer
      get finance_reports_path
      expect(response).to redirect_to(finance_root_path)
    end

    it "does not grant access to Daily Reconciliation" do
      viewer = user_with_dashboard
      sign_in viewer
      get finance_daily_reconciliations_path
      expect(response).to redirect_to(root_path)
    end

    it "grants dashboard access without any other Finance:: permission" do
      viewer = user_with_dashboard
      sign_in viewer
      get finance_root_path
      expect(response).to have_http_status(:ok)
    end
  end

  # Figures read straight off the controller (rather than parsed out of the
  # rendered HTML) so each widget's value is pinned exactly. These guard the
  # query consolidation in Finance::DashboardController — every figure that is
  # now derived from a shared grouped query must equal what its own dedicated
  # query used to return.
  describe "dashboard figures" do
    # Mid-month, midday in the business's zone (Asia/Riyadh, UTC+3), so no
    # date window below straddles a boundary by accident.
    around { |ex| travel_to(Time.utc(2026, 5, 15, 9, 0)) { ex.run } }

    let(:may)      { { from: "2026-05-01", to: "2026-05-31" } }
    let(:other_biz) { create(:business) }

    def figure(name) = controller.instance_variable_get(:"@#{name}")

    def verified_dr(on:, collected:, refund: 0, at_branch: branch)
      pm = PaymentMethod.find_or_create_by!(business: business, name: "Cash") { |m| m.settlement_type = "cash"; m.active = true }
      dr = DailyReconciliation.create!(branch: at_branch, business: business, state: "verified", business_date: on,
                                        opened_at: on.to_time, closed_at: on.to_time,
                                        verified_at: on.to_time, verified_by_id: owner.id)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: pm, payment_method_name: "Cash",
                                 collected_amount: collected, refund_amount: refund)
      dr
    end

    describe "expenses" do
      let(:category) { create(:expense_category, business: business) }

      def expense(amount, on:, **attrs)
        create(:expense, business: business, branch: branch, expense_category: category,
               status: "approved", amount: amount, expense_date: on, **attrs)
      end

      it "totals approved branch + shared expenses for the period and the equal-length previous period" do
        expense(100, on: Date.new(2026, 5, 10))
        # Shared expense (branch_id NULL). Allocation rows are irrelevant to the
        # dashboard's totals, so skip that validation-heavy setup.
        expense(50,  on: Date.new(2026, 5, 11)).update_column(:branch_id, nil)
        expense(999, on: Date.new(2026, 5, 12), status: "pending_approval") # not approved
        expense(70,  on: Date.new(2026, 4, 15))                            # previous period (Mar 31 – Apr 30)
        expense(5,   on: Date.new(2026, 3, 30))                            # before the previous period
        other_cat = create(:expense_category, business: other_biz)
        create(:expense, business: other_biz, branch: create(:branch, business: other_biz), expense_category: other_cat,
               status: "approved", amount: 1000, expense_date: Date.new(2026, 5, 10))

        sign_in owner
        get finance_root_path(may)

        expect(figure(:kpi_expenses)).to eq([ 150, 70 ])
        expect(figure(:by_category)).to eq([ [ category.name, 150 ] ])
        expect(figure(:top_categories).first).to include(name: category.name, amount: 150)
        expect(figure(:top_categories).first[:change]).to be_within(0.0001).of((150 - 70) / 70.0)
      end

      it "narrows every expense figure by the payment-source filter" do
        expense(100, on: Date.new(2026, 5, 10)).update_column(:payment_source, "company_cash")
        expense(40,  on: Date.new(2026, 5, 10)).update_column(:payment_source, "bank_account")
        expense(30,  on: Date.new(2026, 4, 20)).update_column(:payment_source, "company_cash")

        sign_in owner
        get finance_root_path(may.merge(payment_source: "company_cash"))

        expect(figure(:kpi_expenses)).to eq([ 100, 30 ])
        expect(figure(:by_category).to_h.values.sum).to eq(100)
      end
    end

    describe "verified revenue" do
      it "keeps the Revenue KPI, has-data flag and Revenue by Branch consistent for the period" do
        other_branch = create(:branch, business: business)
        verified_dr(on: Date.new(2026, 5, 3), collected: 1000, refund: 100)
        verified_dr(on: Date.new(2026, 5, 4), collected: 500, at_branch: other_branch)
        verified_dr(on: Date.new(2026, 4, 20), collected: 300) # previous period

        sign_in owner
        get finance_root_path(may)

        expect(figure(:kpi_revenue)).to eq([ 1400, 300 ])
        expect(figure(:has_period_revenue)).to be(true)
        expect(figure(:revenue_by_branch).map { |id, _, total| [ id, total ] })
          .to eq([ [ branch.id, 900 ], [ other_branch.id, 500 ] ])
      end

      it "treats a verified day that nets to zero as data, not as the empty state" do
        verified_dr(on: Date.new(2026, 5, 3), collected: 100, refund: 100)

        sign_in owner
        get finance_root_path(may)

        expect(figure(:kpi_revenue).first).to eq(0)
        expect(figure(:has_period_revenue)).to be(true)
        expect(figure(:has_focus_month_revenue)).to be(true)
      end

      it "reports no focus-month revenue when the only verified day is in an earlier trend month" do
        verified_dr(on: Date.new(2026, 4, 20), collected: 300)

        sign_in owner
        get finance_root_path(may)

        expect(figure(:has_focus_month_revenue)).to be(false)
        expect(figure(:has_period_revenue)).to be(false)
        expect(figure(:trend_revenue).last(2)).to eq([ 300.0, 0.0 ])
      end
    end

    describe "remaining deposit balance alerts" do
      def rdb(age_days:, remaining:, status: "open", biz: business, at_branch: branch, on: nil)
        on ||= Date.new(2026, 5, 15) - age_days
        dr = DailyReconciliation.create!(branch: at_branch, business: biz, state: "closed", business_date: on,
                                          opened_at: on.to_time, closed_at: on.to_time)
        RemainingDepositBalance.create!(business: biz, branch: at_branch, daily_reconciliation: dr,
                                         amount: 100, remaining_amount: remaining, status: status,
                                         closed_at: (status == "open" ? nil : Time.current),
                                         responsible_user: owner, created_by: owner,
                                         created_at: age_days.days.ago)
      end

      it "counts and sums open balances and buckets them by age in a single query" do
        business.update!(finance_overdue_days: 3, finance_notify_thresholds: "7,14")
        rdb(age_days: 1,  remaining: 10)
        rdb(age_days: 5,  remaining: 20)
        rdb(age_days: 10, remaining: 30.5)
        rdb(age_days: 20, remaining: 0, status: "settled")
        rdb(age_days: 20, remaining: 99, biz: other_biz, at_branch: create(:branch, business: other_biz))

        sign_in owner
        rdb_queries = 0
        counter = ->(*, payload) { rdb_queries += 1 if payload[:sql].include?("FROM \"remaining_deposit_balances\"") }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get finance_root_path(may) }

        expect(figure(:rdb_open_count)).to eq(3)
        expect(figure(:rdb_open_amount)).to eq(BigDecimal("60.5"))
        expect(figure(:rdb_overdue_count)).to eq(2)
        expect(figure(:rdb_threshold_alerts)).to eq([ { days: 7, count: 1 } ])
        expect(rdb_queries).to eq(1)
      end

      it "reports zero open amount (not nil) when nothing is outstanding" do
        sign_in owner
        get finance_root_path(may)

        expect(figure(:rdb_open_count)).to eq(0)
        expect(figure(:rdb_open_amount)).to eq(0)
        expect(figure(:rdb_threshold_alerts)).to eq([])
      end
    end

    describe "custody" do
      let(:holder)  { create(:user, business: business, first_name: "Holder") }
      let(:account) { create(:custody_account, business: business, branch: branch, user: holder) }

      def txn(amount, at:, **attrs)
        CustodyTransaction.create!(business: business, custody_account: account, amount: amount,
                                   txn_type: amount.positive? ? "top_up" : "expense_deduction", created_at: at, **attrs)
      end

      it "buckets cash flow by business-local day, so an early-morning transaction is not shown on the previous day" do
        riyadh = ActiveSupport::TimeZone["Asia/Riyadh"]
        txn(300,  at: riyadh.local(2026, 5, 10, 1, 30)) # 2026-05-09 22:30 UTC
        txn(-120, at: riyadh.local(2026, 5, 12, 15, 0))
        txn(500,  at: riyadh.local(2026, 5, 12, 16, 0), voided_at: Time.current, void_reason: "duplicate")
        txn(800,  at: riyadh.local(2026, 4, 30, 23, 0)) # outside the range

        sign_in owner
        get finance_root_path(may)

        net = figure(:cash_flow_net)
        expect(net.size).to eq(31)
        expect(net[8]).to eq(0)    # May 9
        expect(net[9]).to eq(300)  # May 10
        expect(net[11]).to eq(-120) # May 12 (voided top-up excluded)
        expect(net.sum).to eq(180)
        expect(figure(:cash_in)).to eq(300)
        expect(figure(:cash_out)).to eq(120)
        expect(figure(:cash_net)).to eq(180)
      end

      it "reports zero cash flow (not nil) for a range with no custody activity" do
        account
        sign_in owner
        get finance_root_path(may)

        expect(figure(:cash_flow_net).uniq).to eq([ 0 ])
        expect([ figure(:cash_in), figure(:cash_out), figure(:cash_net) ]).to eq([ 0, 0, 0 ])
      end

      it "surfaces negative custody balances in the alerts" do
        txn(100, at: 3.days.ago)
        txn(-250, at: 1.day.ago)

        sign_in owner
        get finance_root_path(may)

        expect(figure(:alert_negative_custody)).to eq([ { name: account.name, holder: holder.full_name, balance: -150 } ])
        expect(figure(:custody_negative_count)).to eq(1)
        expect(figure(:kpi_custody_balance).first).to eq(-150)
      end
    end
  end
end
