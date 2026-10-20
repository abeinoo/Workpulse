require "rails_helper"

# Payroll-entry amounts (payslips and per-employee payroll rows) — who may see
# them and the record that they were seen (decisions of 2026-10-19):
# * per-employee pay is shown only for the entries PayrollEntryPolicy's scope
#   allows (an employee their own finalized/paid entries; a payroll viewer those
#   inside the view_payroll scope) — on every surface, including the branch
#   page, the payroll dashboard's top earners, the finance expense-details
#   report and the API period detail;
# * every successful view writes one "view_payroll_entry" AuditLog (actor,
#   subject, source, entry ids — never amounts); refused requests write none.
RSpec.describe "Payroll entry views", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business, branch_type: "sales") }
  let(:branch_b) { create(:branch, business: business, branch_type: "sales") }

  let(:emp_a) { create(:user, business: business).tap { |u| assign(u, branch_a) } }
  let(:emp_b) { create(:user, business: business).tap { |u| assign(u, branch_b) } }

  let(:period)   { create(:payroll_period, :finalized, :last_month, business: business) }
  let!(:entry_a) { create(:payroll_entry, payroll_period: period, user: emp_a, base_salary: 7_123.45, net_salary: 6_987.65) }
  let!(:entry_b) { create(:payroll_entry, payroll_period: period, user: emp_b, base_salary: 8_234.56, net_salary: 8_098.76) }

  A_AMOUNTS = %w[7123.45 7,123 6987.65 6,988 6,987].freeze
  B_AMOUNTS = %w[8234.56 8,235 8,234 8098.76 8,099 8,098].freeze

  def assign(user, branch)
    create(:shift_assignment, business: business, user: user, branch: branch,
                              effective_from: 1.month.ago.to_date, effective_to: nil)
  end

  def role_user(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                              permissions: permissions.map(&:to_s), permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def manager_of(branch, *permissions, scopes: {})
    role_user(*permissions, scopes: scopes).tap { |u| branch.update_column(:branch_manager_id, u.id) }
  end

  def views = AuditLog.where(action: "view_payroll_entry")

  def expect_logged(source:, actor:, entries:, auditable:)
    log = views.last
    expect(log).to have_attributes(actor_id: actor.id, business_id: business.id, auditable: auditable)
    expect(log.metadata).to eq("source" => source, "payroll_entry_ids" => entries.map(&:id),
                               "employee_ids" => entries.map(&:user_id).uniq,
                               "self_view" => entries.map(&:user_id).uniq == [ actor.id ])
    expect(log.changes_json).to eq({})
    # Full decimal amounts: ids (e.g. 688234) can contain the bare digits.
    expect(log.to_json).not_to include("7123.45", "6987.65", "8234.56", "8098.76")
  end

  def expect_none_of(amounts) = amounts.each { |a| expect(response.body).not_to include(a) }

  describe "HTML" do
    it "payslip: the employee's own, audited as a self view" do
      sign_in emp_a
      expect { get payroll_period_payroll_entry_path(period, entry_a) }.to change(views, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect_logged(source: "payslip", actor: emp_a, entries: [ entry_a ], auditable: entry_a)
    end

    it "payslip: another employee's is not found and not audited" do
      sign_in emp_b
      expect { get payroll_period_payroll_entry_path(period, entry_a) }.not_to change(views, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "payslip: an in-scope payroll viewer, audited once" do
      manager = manager_of(branch_a, :view_payroll)
      sign_in manager
      expect { get payroll_period_payroll_entry_path(period, entry_a) }.to change(views, :count).by(1)
      expect_logged(source: "payslip", actor: manager, entries: [ entry_a ], auditable: entry_a)
    end

    it "period page: only the viewer's scoped entries, one event for the page" do
      manager = manager_of(branch_a, :view_payroll)
      sign_in manager
      expect { get payroll_period_path(period) }.to change(views, :count).by(1)

      expect(response.body).to include("6,987")
      expect_none_of(B_AMOUNTS)
      expect_logged(source: "period_entries", actor: manager, entries: [ entry_a ], auditable: entry_a)
    end

    it "period page: a business-wide viewer, audited on the period" do
      viewer = role_user(:view_payroll, scopes: { "view_payroll" => "business" })
      sign_in viewer
      expect { get payroll_period_path(period) }.to change(views, :count).by(1)
      expect_logged(source: "period_entries", actor: viewer, entries: [ entry_a, entry_b ].sort_by { |e| e.user.first_name + e.user.last_name }, auditable: period)
    end

    it "my payslips list: the employee's own entries" do
      sign_in emp_a
      expect { get payroll_periods_path }.to change(views, :count).by(1)
      expect_logged(source: "my_payslips", actor: emp_a, entries: [ entry_a ], auditable: entry_a)
    end

    it "dashboard latest payslip widget" do
      sign_in emp_a
      expect { get root_path }.to change(views, :count).by(1)
      expect_logged(source: "dashboard_latest_payslip", actor: emp_a, entries: [ entry_a ], auditable: entry_a)
    end

    it "payroll dashboard: top earners only within the view_payroll scope" do
      analyst = manager_of(branch_a, :view_payroll, :view_payroll_analytics)
      sign_in analyst
      expect { get payroll_dashboard_path }.to change(views, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(emp_b.full_name)
      expect_logged(source: "payroll_dashboard_top_employees", actor: analyst, entries: [ entry_a ], auditable: entry_a)
    end

    context "branch page" do
      let!(:branch_period) { create(:payroll_period, :finalized, business: business, branch: branch_a) }
      let!(:branch_entry)  { create(:payroll_entry, payroll_period: branch_period, user: emp_a, base_salary: 7_123.45, net_salary: 6_987.65) }

      it "shows no payroll to a branch administrator without view_payroll, and audits nothing" do
        sign_in role_user(:manage_branches)
        expect { get admin_branch_path(branch_a) }.not_to change(views, :count)

        expect(response).to have_http_status(:ok)
        expect_none_of(A_AMOUNTS)
      end

      it "shows a payroll viewer the scoped entries, audited" do
        admin = role_user(:manage_branches, :view_payroll, scopes: { "view_payroll" => "business" })
        sign_in admin
        expect { get admin_branch_path(branch_a) }.to change(views, :count).by(1)

        expect(response.body).to include("7,123")
        expect_logged(source: "branch_payroll_summary", actor: admin, entries: [ branch_entry ], auditable: branch_entry)
      end

      it "hides entries outside the viewer's view_payroll scope" do
        admin = manager_of(branch_b, :manage_branches, :view_payroll)
        sign_in admin
        expect { get admin_branch_path(branch_a) }.not_to change(views, :count)
        expect_none_of(A_AMOUNTS)
      end
    end

    it "bank-transfer export: the exported entries" do
      viewer = role_user(:view_payroll, :export_reports, scopes: { "view_payroll" => "business" })
      allow_any_instance_of(PayrollPeriodPolicy).to receive(:export_payroll_bank_csv?).and_return(true)
      sign_in viewer
      expect { get export_bank_transfer_payroll_period_path(period, format: :csv) }.to change(views, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(views.last.metadata).to include("source" => "bank_transfer_export")
      expect(views.last.metadata["payroll_entry_ids"]).to contain_exactly(entry_a.id, entry_b.id)
    end
  end

  describe "finance expense-details report" do
    let(:params) { { year: period.period_year, month: period.period_month } }

    it "shows no employee pay rows to an expense-report viewer without view_payroll" do
      sign_in role_user(:view_expense_reports)
      expect { get finance_expense_details_report_path(params) }.not_to change(views, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(emp_a.full_name, emp_b.full_name)
    end

    it "shows a payroll viewer only the rows inside the view_payroll scope, audited (HTML and CSV)" do
      viewer = manager_of(branch_a, :view_expense_reports, :view_payroll)
      sign_in viewer
      expect { get finance_expense_details_report_path(params) }.to change(views, :count).by(1)

      expect(response.body).to include(emp_a.full_name)
      expect(response.body).not_to include(emp_b.full_name)
      expect_logged(source: "finance_expense_details", actor: viewer, entries: [ entry_a ], auditable: entry_a)

      expect { get finance_expense_details_report_path(params.merge(format: :csv)) }.to change(views, :count).by(1)
      expect(response.body).to include(emp_a.full_name)
      expect(response.body).not_to include(emp_b.full_name)
      expect(views.last.metadata["source"]).to eq("finance_expense_details_csv")
    end
  end

  describe "API" do
    it "entries index and show: scoped, audited" do
      manager = manager_of(branch_a, :view_payroll)
      sign_in manager

      expect { get "/api/v1/payroll_periods/#{period.id}/payroll_entries", as: :json }.to change(views, :count).by(1)
      expect(api_data.map { |e| e["id"] }).to eq([ entry_a.id ])
      expect_logged(source: "api_payroll_entries", actor: manager, entries: [ entry_a ], auditable: entry_a)

      expect { get "/api/v1/payroll_periods/#{period.id}/payroll_entries/#{entry_a.id}", as: :json }.to change(views, :count).by(1)
      expect(views.last.metadata["source"]).to eq("api_payroll_entry")
    end

    it "entry show outside the scope: not found, not audited" do
      sign_in manager_of(branch_a, :view_payroll)
      expect { get "/api/v1/payroll_periods/#{period.id}/payroll_entries/#{entry_b.id}", as: :json }.not_to change(views, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "entry update response: audited once" do
      editor = role_user(:view_payroll, :regenerate_payroll, scopes: { "view_payroll" => "business" })
      sign_in editor
      expect do
        patch "/api/v1/payroll_periods/#{period.id}/payroll_entries/#{entry_a.id}", params: { payroll_entry: { notes: "checked" } }, as: :json
      end.to change(views, :count).by(1)
      expect(views.last.metadata["source"]).to eq("api_payroll_entry_update")
    end

    # Was: the detailed period listed EVERY entry of the period — an employee
    # with their own payslip in it saw everyone's pay.
    it "period detail: an employee sees only their own entry" do
      sign_in emp_a
      expect { get "/api/v1/payroll_periods/#{period.id}", as: :json }.to change(views, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(api_data["entries"].map { |e| e["id"] }).to eq([ entry_a.id ])
      expect_none_of(%w[8234.56 8098.76])
      expect_logged(source: "api_payroll_period", actor: emp_a, entries: [ entry_a ], auditable: entry_a)
    end

    it "period detail: a branch manager sees only their branch's entries" do
      sign_in manager_of(branch_a, :view_payroll)
      get "/api/v1/payroll_periods/#{period.id}", as: :json
      expect(api_data["entries"].map { |e| e["id"] }).to eq([ entry_a.id ])
    end

    it "payroll report summary and export: scoped, audited" do
      analyst = manager_of(branch_a, :view_payroll, :view_payroll_analytics)
      sign_in analyst

      expect { get "/api/v1/reports/payroll/summary", params: { payroll_period_id: period.id }, as: :json }
        .to change(views, :count).by(1)
      expect(views.last.metadata).to include("source" => "api_payroll_report_summary", "payroll_entry_ids" => [ entry_a.id ])

      expect { get "/api/v1/reports/payroll/export", params: { payroll_period_id: period.id } }
        .to change(views, :count).by(1)
      expect(views.last.metadata).to include("source" => "api_payroll_report_export", "payroll_entry_ids" => [ entry_a.id ])
    end

    it "a plain employee's refused report request writes nothing" do
      sign_in emp_a
      expect { get "/api/v1/reports/payroll/summary", params: { payroll_period_id: period.id }, as: :json }
        .not_to change(views, :count)
    end
  end
end
