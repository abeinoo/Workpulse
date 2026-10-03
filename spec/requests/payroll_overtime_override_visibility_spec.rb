require "rails_helper"

# The overtime-override card on the payroll entry page (calculated vs approved
# overtime, withheld difference, who/when/why) is payroll-reviewer data. A
# regular employee viewing their own payslip must not receive it — in the HTML,
# in the JSON API, or via the override endpoints — while still seeing their
# normal salary breakdown (base, payable overtime, net).
RSpec.describe "Payroll overtime override visibility", type: :request do
  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:employee)   { create(:user, business: business) }

  # The realistic leak case: an employee role granted view_payroll scoped to
  # "self" so staff can open their own payslip.
  let(:self_viewer) { user_with(%w[view_payroll], scopes: { "view_payroll" => "self" }) }

  # Branch reviewer persona — no override authority, but reviews payroll.
  let(:reviewer) do
    user_with(%w[view_payroll complete_branch_review],
              scopes: { "view_payroll" => "business", "complete_branch_review" => "business" })
  end

  let(:override_reason) { "Forgot to check out on Thursday" }
  let(:card_marker)     { '<div class="ot-override-card' }

  def user_with(permissions, scopes: {})
    role = create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
    create(:user, business: business, permission_role: role)
  end

  # 240 calculated minutes worth 300, overridden down to 150 (120 min).
  def overridden_entry(period, user)
    create(:payroll_entry,
           payroll_period: period, user: user,
           base_salary: 5_000.0, total_overtime: 150.0, net_salary: 5_150.0,
           calculated_overtime_minutes: 240, calculated_overtime_pay: 300.0,
           approved_overtime_minutes: 120, approved_overtime_pay: 150.0,
           overtime_override_mode: "amount", overtime_override_reason: override_reason,
           overtime_overridden_by: accountant, overtime_overridden_at: Time.current)
  end

  # Entry backed by an overtime line item so recalculate_totals! keeps the
  # calculated figures in sync (mirrors Payroll::OvertimeOverrider's spec).
  def overridable_entry(period, user)
    entry = create(:payroll_entry,
                   payroll_period: period, user: user,
                   total_overtime: 300.0, net_salary: 5_300.0,
                   calculated_overtime_minutes: 240, calculated_overtime_pay: 300.0)
    create(:payroll_line_item, :overtime, payroll_entry: entry, amount: 300.0)
    entry
  end

  describe "GET payroll entry page" do
    let(:period) { create(:payroll_period, :finalized, business: business) }

    context "as a regular employee (no payroll permissions) viewing their own payslip" do
      let!(:entry) { overridden_entry(period, employee) }

      before { sign_in employee }

      it "does not render the overtime override card or its data" do
        get payroll_period_payroll_entry_path(period, entry)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(card_marker)
        expect(response.body).not_to include(override_reason)
        expect(response.body).not_to include(override_overtime_payroll_period_payroll_entry_path(period, entry))
      end

      it "still shows the normal salary breakdown" do
        get payroll_period_payroll_entry_path(period, entry)

        expect(response.body).to include("5,000.00") # base salary
        expect(response.body).to include("150.00")   # payable overtime
        expect(response.body).to include("5,150.00") # net salary
      end
    end

    context "as an employee whose role grants self-scoped view_payroll" do
      let!(:entry) { overridden_entry(period, self_viewer) }

      before { sign_in self_viewer }

      it "does not render the overtime override card or its data" do
        get payroll_period_payroll_entry_path(period, entry)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(card_marker)
        expect(response.body).not_to include(override_reason)
        expect(response.body).to include("5,150.00")
      end

      it "does not render the override badge on the period page" do
        get payroll_period_path(period)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(I18n.t("payroll.overtime_override.badge"))
      end
    end

    context "as an authorised payroll user" do
      let!(:entry) { overridden_entry(period, employee) }

      it "renders the card with the override details for an accountant" do
        sign_in accountant
        get payroll_period_payroll_entry_path(period, entry)

        expect(response.body).to include(card_marker)
        expect(response.body).to include(override_reason)
      end

      it "renders the card for a branch reviewer" do
        sign_in reviewer
        get payroll_period_payroll_entry_path(period, entry)

        expect(response.body).to include(card_marker)
        expect(response.body).to include(override_reason)
      end

      it "renders the override badge on the period page" do
        sign_in accountant
        get payroll_period_path(period)

        expect(response.body).to include(I18n.t("payroll.overtime_override.badge"))
      end
    end
  end

  describe "GET /api/v1 payroll entry" do
    let(:period) { create(:payroll_period, :finalized, business: business) }
    let!(:entry) { overridden_entry(period, employee) }

    it "returns the employee's payslip without reviewer-only override fields" do
      sign_in employee
      get "/api/v1/payroll_periods/#{period.id}/payroll_entries/#{entry.id}", as: :json

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["net_salary"].to_d).to eq(5_150)
      expect(data["total_overtime"].to_d).to eq(150)
      expect(data.keys).not_to include(
        "calculated_overtime_minutes", "calculated_overtime_pay",
        "approved_overtime_minutes", "approved_overtime_pay",
        "overtime_override_mode", "overtime_override_reason",
        "overtime_overridden_by_id", "overtime_overridden_at", "overtime_override_stale"
      )
      expect(response.body).not_to include(override_reason)
    end
  end

  describe "override endpoints" do
    let(:period) { create(:payroll_period, :under_review, business: business) }

    describe "PATCH override_overtime" do
      it "rejects a regular employee overriding their own overtime" do
        entry = overridable_entry(period, employee)
        sign_in employee

        expect {
          patch override_overtime_payroll_period_payroll_entry_path(period, entry),
                params: { mode: "amount", value: 999, reason: "self-approve" }
        }.not_to change { entry.reload.attributes }
        expect(entry).not_to be_overtime_overridden
      end

      it "rejects a payroll viewer without manage_payroll_overrides even when the entry is visible" do
        viewer = user_with(%w[view_payroll view_draft_payroll], scopes: { "view_payroll" => "business" })
        entry  = overridable_entry(period, employee)
        sign_in viewer

        expect {
          patch override_overtime_payroll_period_payroll_entry_path(period, entry),
                params: { mode: "amount", value: 0, reason: "x" }
        }.not_to change { entry.reload.attributes }
      end

      it "lets an authorised user override, with unchanged payroll arithmetic" do
        entry = overridable_entry(period, employee)
        sign_in accountant

        patch override_overtime_payroll_period_payroll_entry_path(period, entry),
              params: { mode: "amount", value: 150, reason: "Partial approval" }

        expect(response).to redirect_to(payroll_period_payroll_entry_path(period, entry))
        entry.reload
        expect(entry).to be_overtime_overridden
        expect(entry.calculated_overtime_pay).to eq(300.0)
        expect(entry.calculated_overtime_minutes).to eq(240)
        expect(entry.total_overtime).to eq(150.0)
        expect(entry.approved_overtime_minutes).to eq(120)
        expect(entry.net_salary).to eq(5_150.0)
      end
    end

    describe "PATCH adjust_overtime (bulk)" do
      it "rejects a regular employee" do
        entry = overridable_entry(period, employee)
        sign_in employee

        expect {
          patch adjust_overtime_payroll_period_path(period),
                params: { entry_ids: [ entry.id ], bulk_mode: "zero", reason: "x" }
        }.not_to change { entry.reload.attributes }
      end

      it "lets an authorised user zero overtime" do
        entry = overridable_entry(period, employee)
        sign_in accountant

        patch adjust_overtime_payroll_period_path(period),
              params: { entry_ids: [ entry.id ], bulk_mode: "zero", reason: "Missed check-out" }

        entry.reload
        expect(entry.total_overtime).to eq(0.0)
        expect(entry.net_salary).to eq(5_000.0)
        expect(entry.calculated_overtime_pay).to eq(300.0)
      end
    end
  end
end
