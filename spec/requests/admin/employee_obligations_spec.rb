require "rails_helper"

RSpec.describe "Admin::EmployeeObligations", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }

  let(:period) { create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22) }

  let!(:obligation) do
    create(:employee_obligation,
           user: employee, business: business, created_by: owner,
           start_month: 6, start_year: 2026,
           total_amount: 1_500.0, remaining_amount: 1_500.0, installment_amount: 500.0)
  end

  before { sign_in owner }

  describe "GET /admin/employee_obligations/:id/edit" do
    it "renders the edit form when not locked" do
      get edit_admin_employee_obligation_path(obligation)
      expect(response).to have_http_status(:ok)
    end

    it "redirects with an alert once a deduction's period is finalized" do
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period)
      period.update_column(:status, "finalized")

      get edit_admin_employee_obligation_path(obligation)

      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      follow_redirect!
      expect(response.body).to include(I18n.t("admin.employee_obligations.locked_for_edit"))
    end
  end

  describe "PATCH /admin/employee_obligations/:id" do
    it "updates the obligation and recalculates affected payroll" do
      create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: 1.year.ago.to_date)
      Payroll::EntryCalculator.call(period: period, user: employee, business: business)
      expect(ObligationDeduction.where(payroll_period: period)).to be_present

      patch admin_employee_obligation_path(obligation),
            params: { employee_obligation: { start_month: 7, start_year: 2026,
                                              total_amount: 1_500.0, installment_amount: 500.0 } }

      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(obligation.reload.start_month).to eq(7)
      expect(ObligationDeduction.where(payroll_period: period)).to be_empty
    end

    it "refuses the update once a deduction's period is finalized" do
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period)
      period.update_column(:status, "finalized")

      patch admin_employee_obligation_path(obligation),
            params: { employee_obligation: { start_month: 7, start_year: 2026,
                                              total_amount: 1_500.0, installment_amount: 500.0 } }

      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(obligation.reload.start_month).to eq(6)
    end
  end

  describe "PATCH /admin/employee_obligations/:id/postpone" do
    let!(:loan) do
      create(:employee_obligation, :open_ended,
             user: employee, business: business, created_by: owner,
             start_month: 8, start_year: 2026,
             total_amount: 12_000.0, remaining_amount: 12_000.0, installment_amount: 2_000.0,
             installments_count: 6)
    end

    it "postpones to next month and redirects with a success notice" do
      patch postpone_admin_employee_obligation_path(loan),
            params: { year: 2026, month: 8, postponement_type: "next_month" }

      expect(response).to redirect_to(admin_employee_obligation_path(loan))
      follow_redirect!
      expect(response.body).to include(I18n.t("admin.employee_obligations.postponement.success"))
      schedule = loan.reload.installment_schedule
      expect(schedule.find { |e| e[:month] == 9 && e[:year] == 2026 }[:amount]).to eq(4_000.0)
    end

    it "extends the loan schedule by one month" do
      patch postpone_admin_employee_obligation_path(loan),
            params: { year: 2026, month: 8, postponement_type: "extend_loan" }

      expect(response).to redirect_to(admin_employee_obligation_path(loan))
      expect(loan.reload.installment_schedule.size).to eq(7)
    end

    it "redirects with an alert when the installment's period is already finalized" do
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 8, status: "finalized")
      create(:obligation_deduction, employee_obligation: loan, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)

      patch postpone_admin_employee_obligation_path(loan),
            params: { year: 2026, month: 8, postponement_type: "next_month" }

      expect(response).to redirect_to(admin_employee_obligation_path(loan))
      follow_redirect!
      expect(response.body).to include(I18n.t("admin.employee_obligations.postponement.not_eligible"))
    end

    it "still succeeds when the installment only has a draft (non-finalized) deduction" do
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 8, status: "draft")
      create(:obligation_deduction, employee_obligation: loan, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)

      patch postpone_admin_employee_obligation_path(loan),
            params: { year: 2026, month: 8, postponement_type: "next_month" }

      expect(response).to redirect_to(admin_employee_obligation_path(loan))
      follow_redirect!
      expect(response.body).to include(I18n.t("admin.employee_obligations.postponement.success"))
      expect(ObligationDeduction.where(employee_obligation: loan, payroll_period: period)).to be_empty
      expect(loan.reload.remaining_amount).to eq(12_000.0)
    end

    it "denies access to a user without manage_obligations permission" do
      sign_out owner
      plain_user = create(:user, business: business)
      sign_in plain_user

      patch postpone_admin_employee_obligation_path(loan),
            params: { year: 2026, month: 8, postponement_type: "next_month" }

      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/employee_obligations" do
    let(:sara) { create(:user, business: business, first_name: "Sara", last_name: "Nasser", employee_code: "E-77") }
    let(:branch) { create(:branch, business: business, name: "Olaya") }

    let!(:laptop) do
      create(:employee_obligation, :with_end_date,
             user: sara, business: business, created_by: owner, obligation_type: "equipment",
             title: "Laptop installment", start_month: 1, start_year: 2026,
             total_amount: 900.0, remaining_amount: 300.0, installment_amount: 300.0)
    end
    let!(:done) do
      create(:employee_obligation, :completed,
             user: sara, business: business, created_by: owner, title: "Old loan",
             start_month: 3, start_year: 2025, total_amount: 500.0, installment_amount: 500.0)
    end
    let!(:cancelled_with_balance) do
      create(:employee_obligation, :cancelled,
             user: employee, business: business, created_by: owner, title: "Dropped loan",
             total_amount: 800.0, remaining_amount: 800.0, installment_amount: 400.0)
    end

    def listed_titles
      Nokogiri::HTML(response.body).css(".obl-title").map { |n| n.text.strip }
    end

    # [total, active, completed, outstanding total (digits only)]
    def summary_values
      values = Nokogiri::HTML(response.body).css(".obl-summary .stat-card__value").map { |n| n.text.strip }
      values[0..2] + [ values[3].gsub(/[^\d.]/, "") ]
    end

    it "lists every visible obligation with the summary figures" do
      get admin_employee_obligations_path

      expect(response).to have_http_status(:ok)
      expect(listed_titles).to contain_exactly(obligation.title, "Laptop installment", "Old loan", "Dropped loan")
      summary = Nokogiri::HTML(response.body).css(".obl-summary .stat-card__value").map { |n| n.text.strip }
      expect(summary[0..2]).to eq(%w[4 2 1])
      # Outstanding = live (active/paused) obligations only: 1,500 + 300. The
      # cancelled obligation's leftover 800 is not counted.
      expect(summary[3]).to include("1,800.00")
    end

    it "searches by employee name, employee code and obligation title" do
      get admin_employee_obligations_path(q: "nasser")
      expect(listed_titles).to contain_exactly("Laptop installment", "Old loan")

      get admin_employee_obligations_path(q: "e-77")
      expect(listed_titles).to contain_exactly("Laptop installment", "Old loan")

      get admin_employee_obligations_path(q: "laptop")
      expect(listed_titles).to eq([ "Laptop installment" ])
    end

    it "treats LIKE wildcards in the search term literally" do
      get admin_employee_obligations_path(q: "%")
      expect(listed_titles).to be_empty
    end

    it "filters by employee, type and status" do
      get admin_employee_obligations_path(user_id: sara.id)
      expect(listed_titles).to contain_exactly("Laptop installment", "Old loan")

      get admin_employee_obligations_path(obligation_type: "equipment")
      expect(listed_titles).to eq([ "Laptop installment" ])

      get admin_employee_obligations_path(status: "cancelled")
      expect(listed_titles).to eq([ "Dropped loan" ])
    end

    it "ignores unknown filter values instead of erroring" do
      get admin_employee_obligations_path(status: "bogus", obligation_type: "nope", balance: "x", start_from: "not-a-date")
      expect(response).to have_http_status(:ok)
      expect(listed_titles.size).to eq(4)
    end

    it "filters by the employee's current branch (via shift assignment)" do
      create(:shift_assignment, business: business, user: sara, branch: branch)

      get admin_employee_obligations_path(branch_id: branch.id)
      expect(listed_titles).to contain_exactly("Laptop installment", "Old loan")
    end

    it "filters by remaining balance" do
      get admin_employee_obligations_path(balance: "outstanding")
      expect(listed_titles).to contain_exactly(obligation.title, "Laptop installment")

      get admin_employee_obligations_path(balance: "repaid")
      expect(listed_titles).to eq([ "Old loan" ])
    end

    it "filters by start month range" do
      get admin_employee_obligations_path(start_from: "2026-01", start_to: "2026-05")
      expect(listed_titles).to eq([ "Laptop installment" ])

      get admin_employee_obligations_path(start_from: "2025-03", start_to: "2025-03")
      expect(listed_titles).to eq([ "Old loan" ])
    end

    it "offers only the start months that exist, labelled as months" do
      get admin_employee_obligations_path

      options = Nokogiri::HTML(response.body).css("select#start_from option").map { |o| [ o["value"], o.text ] }
      expect(options).to include([ "2026-01", "January 2026" ], [ "2025-03", "March 2025" ])
      expect(options.map(&:first)).not_to include("2026-02")
    end

    describe "month filter labels" do
      it "reads Start month / End month in English" do
        get admin_employee_obligations_path
        html = Nokogiri::HTML(response.body)
        expect(html.at_css("label[for='start_from']").text).to eq("Start month")
        expect(html.at_css("label[for='start_to']").text).to eq("End month")
        expect(html.css("input[type='date']")).to be_empty
      end

      it "reads من شهر / إلى شهر in Arabic" do
        owner.update!(preferred_locale: "ar")
        get admin_employee_obligations_path(start_from: "2026-01")
        html = Nokogiri::HTML(response.body)
        expect(html.at_css("label[for='start_from']").text).to eq("من شهر")
        expect(html.at_css("label[for='start_to']").text).to eq("إلى شهر")
        expect(html.at_css(".filter-chip").text).to include("من شهر", "يناير 2026")
      end
    end

    it "combines search with filters" do
      get admin_employee_obligations_path(q: "sara", balance: "outstanding")
      expect(listed_titles).to eq([ "Laptop installment" ])
    end

    it "sorts server-side by remaining balance" do
      get admin_employee_obligations_path(sort: "remaining", dir: "desc")
      expect(listed_titles.first(2)).to eq([ obligation.title, "Dropped loan" ])

      get admin_employee_obligations_path(sort: "remaining", dir: "asc")
      expect(listed_titles.first).to eq("Old loan")
    end

    it "paginates and keeps filters + sort in the page links" do
      create_list(:employee_obligation, 21, user: employee, business: business, created_by: owner)

      get admin_employee_obligations_path(status: "active", sort: "total", dir: "asc")
      expect(listed_titles.size).to eq(20)
      page2 = Nokogiri::HTML(response.body).css(".pagination a").find { |a| a.text.strip == "2" }["href"]
      expect(page2).to include("status=active", "sort=total", "dir=asc", "page=2")

      get page2
      expect(listed_titles.size).to eq(3) # 21 + obligation + laptop = 23 active

      get admin_employee_obligations_path(status: "active", per: 50)
      expect(listed_titles.size).to eq(23)
    end

    describe "summary cards follow the current filters" do
      # Fixture recap: obligation (employee, active, 1,500 left), laptop (sara,
      # active, 300 left), done (sara, completed), cancelled_with_balance
      # (employee, cancelled, 800 left — never counted as outstanding).
      it "covers everything with no filters" do
        get admin_employee_obligations_path
        expect(summary_values).to eq(%w[4 2 1 1800.00])
      end

      it "narrows to the selected employee" do
        get admin_employee_obligations_path(user_id: sara.id)
        expect(summary_values).to eq(%w[2 1 1 300.00])
      end

      it "narrows to the selected branch" do
        create(:shift_assignment, business: business, user: employee, branch: branch)

        get admin_employee_obligations_path(branch_id: branch.id)
        expect(summary_values).to eq(%w[2 1 0 1500.00])
      end

      it "narrows to the selected status" do
        get admin_employee_obligations_path(status: "completed")
        expect(summary_values).to eq(%w[1 0 1 0.00])
      end

      it "narrows to the remaining-balance filter" do
        get admin_employee_obligations_path(balance: "outstanding")
        expect(summary_values).to eq(%w[2 2 0 1800.00])

        get admin_employee_obligations_path(balance: "repaid")
        expect(summary_values).to eq(%w[1 0 1 0.00])
      end

      it "narrows to the search term" do
        get admin_employee_obligations_path(q: "laptop")
        expect(summary_values).to eq(%w[1 1 0 300.00])
      end

      it "reflects branch + status + type + balance combined" do
        create(:shift_assignment, business: business, user: sara, branch: branch)

        get admin_employee_obligations_path(branch_id: branch.id, status: "active",
                                            obligation_type: "equipment", balance: "outstanding")
        expect(listed_titles).to eq([ "Laptop installment" ])
        expect(summary_values).to eq(%w[1 1 0 300.00])

        get admin_employee_obligations_path(branch_id: branch.id, status: "active", obligation_type: "cash_loan")
        expect(summary_values).to eq(%w[0 0 0 0.00])
      end

      it "is not affected by pagination or sorting" do
        create_list(:employee_obligation, 25, user: employee, business: business, created_by: owner,
                    total_amount: 100.0, remaining_amount: 100.0, installment_amount: 100.0)
        expected = %w[29 27 1 4300.00]

        get admin_employee_obligations_path
        expect(summary_values).to eq(expected)
        get admin_employee_obligations_path(page: 2)
        expect(listed_titles.size).to eq(9)
        expect(summary_values).to eq(expected)
        get admin_employee_obligations_path(sort: "remaining", dir: "asc", per: 50)
        expect(summary_values).to eq(expected)
        get admin_employee_obligations_path(sort: "employee", dir: "desc", page: 2)
        expect(summary_values).to eq(expected)
      end

      it "card links add their filter on top of the current ones" do
        get admin_employee_obligations_path(user_id: sara.id, sort: "total", dir: "asc")
        hrefs = Nokogiri::HTML(response.body).css(".obl-summary a").map { |a| a["href"] }
        expect(hrefs[1]).to include("user_id=#{sara.id}", "status=active", "sort=total")
        expect(hrefs[3]).to include("user_id=#{sara.id}", "balance=outstanding")
      end
    end

    it "distinguishes 'no results' from 'no data'" do
      get admin_employee_obligations_path(q: "zzz-no-match")
      expect(response.body).to include(I18n.t("admin.employee_obligations.index.no_results_title"))
      expect(response.body).not_to include(I18n.t("admin.employee_obligations.index.empty_title"))
    end

    it "remembers the filters for the detail page's back link" do
      get admin_employee_obligations_path(status: "active", q: "sara")
      get admin_employee_obligation_path(laptop)

      back = Nokogiri::HTML(response.body).at_css("a.back-link")["href"]
      expect(back).to include("status=active", "q=sara")
    end

    context "when the business has no obligations" do
      before { EmployeeObligation.delete_all }

      it "shows the empty state with the create action" do
        get admin_employee_obligations_path
        expect(response.body).to include(I18n.t("admin.employee_obligations.index.empty_title"))
        expect(response.body).to include(new_admin_employee_obligation_path)
        expect(response.body).not_to include(I18n.t("admin.employee_obligations.index.no_results_title"))
      end
    end

    context "without manage_obligations" do
      it "redirects away" do
        sign_in employee
        get admin_employee_obligations_path
        expect(response).to redirect_to(root_path)
      end
    end

    context "with a branch-scoped manage_obligations role" do
      let(:manager) do
        role = create(:permission_role, business: business,
                      permissions: %w[view_employees manage_obligations],
                      permission_scopes: { "manage_obligations" => "branch" })
        create(:user, business: business, permission_role: role)
      end

      before do
        branch.update!(branch_manager_id: manager.id)
        create(:shift_assignment, business: business, user: sara, branch: branch)
        sign_in manager
      end

      it "lists and summarises only in-scope obligations, and filter options stay in scope" do
        get admin_employee_obligations_path

        expect(listed_titles).to contain_exactly("Laptop installment", "Old loan")
        summary = Nokogiri::HTML(response.body).css(".obl-summary .stat-card__value").map { |n| n.text.strip }
        expect(summary[0]).to eq("2")
        employee_options = Nokogiri::HTML(response.body).css("select#user_id option").map(&:text)
        expect(employee_options).not_to include(employee.full_name)
      end

      it "cannot reach out-of-scope obligations through the employee filter" do
        get admin_employee_obligations_path(user_id: employee.id)
        expect(listed_titles).to be_empty
      end
    end
  end
end
