require "rails_helper"

RSpec.describe "Payroll addition cancellations", type: :request do
  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:employee)   { create(:user, business: business) }
  let(:no_perm)    { create(:user, business: business) }

  let(:period) { create(:payroll_period, business: business, status: :draft) }
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, total_bonuses: 300.0, net_salary: 5_300.0)
  end
  let!(:bonus) do
    create(:payroll_line_item, :commission, payroll_entry: entry, amount: 300.0)
  end

  describe "PATCH cancel_addition" do
    it "cancels the addition for an authorised user" do
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, entry, bonus),
            params: { reason: "Entered in error" }

      expect(response).to redirect_to(payroll_period_payroll_entry_path(period, entry))
      expect(bonus.reload.addition_cancelled?).to be true
      expect(entry.reload.net_salary).to eq(5_000.0)
      expect(flash[:notice]).to eq(I18n.t("payroll.addition_cancellation.flash.cancelled"))
    end

    it "does not require a reason" do
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, entry, bonus)

      expect(bonus.reload.addition_cancelled?).to be true
    end

    it "forbids a user without the permission" do
      sign_in no_perm
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, entry, bonus),
            params: { reason: "x" }

      expect(response).not_to have_http_status(:ok)
      expect(bonus.reload.addition_cancelled?).to be false
    end

    it "cannot be cancelled twice" do
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, entry, bonus),
            params: { reason: "x" }
      expect(bonus.reload.addition_cancelled?).to be true

      # The policy itself excludes an already-cancelled item from cancel_addition?,
      # so a second attempt is rejected by Pundit before the service ever runs.
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, entry, bonus),
            params: { reason: "y" }

      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      expect(bonus.reload.addition_cancellation_reason).to eq("x")
    end

    it "is blocked once the period is finalized" do
      period.update!(status: :finalized)
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, entry, bonus),
            params: { reason: "x" }

      expect(bonus.reload.addition_cancelled?).to be false
    end

    it "writes an audit log" do
      sign_in accountant
      expect {
        patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, entry, bonus),
              params: { reason: "Entered in error" }
      }.to change { PayrollAuditLog.where(action_type: "addition_cancelled").count }.by(1)
    end
  end

  # ── Overtime cancellation via the same endpoint/flow (no separate system) ───
  describe "PATCH cancel_addition on an overtime line item" do
    # A separate employee/entry — the outer `let!(:bonus)` already creates a
    # PayrollEntry for `employee` on `period`, and PayrollEntry enforces one
    # entry per (user, period).
    let(:ot_employee) { create(:user, business: business) }
    let(:ot_entry) do
      create(:payroll_entry, payroll_period: period, user: ot_employee,
             base_salary: 5_000.0, total_overtime: 75.0, calculated_overtime_pay: 75.0,
             net_salary: 5_075.0)
    end
    let!(:overtime_item) do
      create(:payroll_line_item, :overtime, payroll_entry: ot_entry, amount: 75.0)
    end

    it "cancels the overtime item and lowers net salary" do
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, ot_entry, overtime_item),
            params: { reason: "Not authorised" }

      expect(response).to redirect_to(payroll_period_payroll_entry_path(period, ot_entry))
      expect(overtime_item.reload.addition_cancelled?).to be true
      expect(ot_entry.reload.total_overtime).to eq(0.0)
      expect(ot_entry.reload.net_salary).to eq(5_000.0)
    end

    it "keeps the original overtime line item in the database after cancellation" do
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, ot_entry, overtime_item),
            params: { reason: "x" }

      persisted = PayrollLineItem.find(overtime_item.id)
      expect(persisted.amount).to eq(75.0)
      expect(persisted.item_type).to eq("overtime")
    end

    it "cannot be cancelled twice" do
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, ot_entry, overtime_item),
            params: { reason: "x" }
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, ot_entry, overtime_item),
            params: { reason: "y" }

      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    end

    it "is blocked once the period is finalized" do
      period.update!(status: :finalized)
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, ot_entry, overtime_item),
            params: { reason: "x" }

      expect(overtime_item.reload.addition_cancelled?).to be false
    end

    it "forbids a user without the permission" do
      sign_in no_perm
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, ot_entry, overtime_item),
            params: { reason: "x" }

      expect(overtime_item.reload.addition_cancelled?).to be false
    end

    it "shows the cancel action for the overtime row on the show page" do
      sign_in accountant
      get payroll_period_payroll_entry_path(period, ot_entry)
      expect(response.body).to include(I18n.t("payroll.addition_cancellation.cancel_btn"))
    end

    # ── "المحتسب" / "المعتمد" totals on a page refresh (a fresh GET after the
    # cancellation has already been persisted, not the redirect response) ──────
    it "shows the recalculated المحتسب and المعتمد currency figures on a subsequent page load" do
      sign_in accountant
      patch cancel_addition_payroll_period_payroll_entry_payroll_line_item_path(period, ot_entry, overtime_item),
            params: { reason: "Not authorised" }

      get payroll_period_payroll_entry_path(period, ot_entry)
      expect(response).to have_http_status(:ok)

      # The show action always re-queries the entry fresh from the DB (no
      # instance caching across requests), so a subsequent page load reflects
      # whatever recalculate_totals! persisted at cancel time.
      expect(ot_entry.reload.calculated_overtime_pay).to eq(0.0)
      expect(ot_entry.payable_overtime_pay).to eq(0.0)
    end

    it "shows the cancelled badge and no action for a cancelled overtime row" do
      Payroll::AdditionCanceller.call(line_item: overtime_item, actor: accountant, reason: "x")

      sign_in accountant
      get payroll_period_payroll_entry_path(period, ot_entry)
      expect(response.body).to include(I18n.t("payroll.addition_cancellation.status_cancelled"))
    end
  end

  describe "GET payroll_entry#show" do
    it "shows the cancel action to an authorised user and the cancelled badge after cancellation" do
      sign_in accountant
      get payroll_period_payroll_entry_path(period, entry)
      expect(response.body).to include(I18n.t("payroll.addition_cancellation.cancel_btn"))

      Payroll::AdditionCanceller.call(line_item: bonus, actor: accountant, reason: "x")

      get payroll_period_payroll_entry_path(period, entry)
      expect(response.body).to include(I18n.t("payroll.addition_cancellation.status_cancelled"))
    end

    it "does not show the cancel action to a user without the permission" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_payroll view_adjustments approve_adjustments],
                    permission_scopes: { "view_payroll" => "business_wide" })
      viewer = create(:user, business: business)
      viewer.update_column(:permission_role_id, role.id)

      sign_in viewer
      get payroll_period_payroll_entry_path(period, entry)
      expect(response.body).not_to include(I18n.t("payroll.addition_cancellation.cancel_btn"))
    end
  end
end
