require "rails_helper"

# Characterization (Milestone 2 Pilot 2, M1) — CURRENT pause / resume / cancel
# behaviour of Admin::EmployeeObligationsController after AP-D4 (6177e8b).
# Pinned here: allowed transitions, refused transitions and their alerts, and
# that the status change and the open-payroll rebuild are atomic. The payroll
# effect of each transition is in spec/requests/payroll_obligation_lifecycle_spec.rb
# (AP-D4 regression); self-management refusal in
# spec/requests/security/employee_obligations_authorization_spec.rb (SEC-M2-10).
#
# Known technical debt (TD-AP9, not changed by M1): the transitions live in the
# controller with no service, no audit log and no reason.
RSpec.describe "Characterization: employee obligation lifecycle", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:obligation) { create(:employee_obligation, business: business, user: employee, created_by: owner) }

  before { sign_in owner }

  def expect_refused(alert_key)
    expect(response).to redirect_to(admin_employee_obligation_path(obligation))
    expect(flash[:alert]).to eq(I18n.t("admin.employee_obligations.#{alert_key}"))
  end

  describe "allowed transitions" do
    it "pauses an active obligation, resumes it, then cancels it, each with its notice" do
      patch pause_admin_employee_obligation_path(obligation)
      expect(obligation.reload).to be_paused
      expect(flash[:notice]).to eq(I18n.t("admin.employee_obligations.paused"))

      patch resume_admin_employee_obligation_path(obligation)
      expect(obligation.reload).to be_active
      expect(flash[:notice]).to eq(I18n.t("admin.employee_obligations.resumed"))

      patch cancel_admin_employee_obligation_path(obligation)
      expect(obligation.reload).to be_cancelled
      expect(flash[:notice]).to eq(I18n.t("admin.employee_obligations.cancelled"))
    end

    it "cancels a paused obligation" do
      obligation.update_column(:status, "paused")
      patch cancel_admin_employee_obligation_path(obligation)
      expect(obligation.reload).to be_cancelled
    end

    it "keeps the remaining balance on cancellation (no write-off entry)" do
      obligation.update_columns(remaining_amount: 1_200)
      patch cancel_admin_employee_obligation_path(obligation)
      expect(obligation.reload).to have_attributes(status: "cancelled", remaining_amount: 1_200)
    end
  end

  describe "refused transitions (status unchanged, alert shown)" do
    it "refuses to pause a non-active obligation" do
      obligation.update_column(:status, "paused")
      patch pause_admin_employee_obligation_path(obligation)
      expect_refused(:cannot_pause)
      expect(obligation.reload).to be_paused
    end

    it "refuses to resume a non-paused obligation" do
      patch resume_admin_employee_obligation_path(obligation)
      expect_refused(:cannot_resume)
      expect(obligation.reload).to be_active
    end

    it "refuses to cancel a completed or an already-cancelled obligation" do
      obligation.update_column(:status, "completed")
      patch cancel_admin_employee_obligation_path(obligation)
      expect_refused(:cannot_cancel)
      expect(obligation.reload).to be_completed

      obligation.update_column(:status, "cancelled")
      patch cancel_admin_employee_obligation_path(obligation)
      expect_refused(:cannot_cancel)
    end
  end

  describe "atomicity with the open-payroll rebuild (AP-D4)" do
    it "rolls the status change back when the payroll rebuild fails" do
      allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for).and_raise(StandardError, "rebuild failed")

      expect { patch pause_admin_employee_obligation_path(obligation) }.to raise_error(StandardError, "rebuild failed")
      expect(obligation.reload).to be_active
    end

    it "rebuilds the obligation owner's open payroll, triggered by the actor" do
      allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for)

      patch cancel_admin_employee_obligation_path(obligation)

      expect(Payroll::EntryRecalculator).to have_received(:recalculate_all_open_periods_for)
        .with(user: employee, triggered_by: owner).once
    end

    it "does not rebuild payroll for a refused transition" do
      allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for)

      patch resume_admin_employee_obligation_path(obligation)

      expect(Payroll::EntryRecalculator).not_to have_received(:recalculate_all_open_periods_for)
    end
  end
end
