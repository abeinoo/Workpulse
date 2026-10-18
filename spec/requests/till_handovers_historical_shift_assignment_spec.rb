require "rails_helper"

# Regression coverage for two bugs discovered on the "Cashier Operations /
# تسليم الكاشير" modal for a HISTORICAL Daily Reconciliation, once the
# underlying DR-visibility fix already let the employee reach the DR itself:
#
# Bug 1 — the colleague/handover-recipient list was built from
# TillHandoversController#resolve_branch's `@branch`, which unconditionally
# preferred the actor's own current_user.effective_branch_on(Date.current)
# (Shoubra) over the explicit daily_reconciliation_id param the DR show page
# passes — so a Nasr City historical DR's modal showed Shoubra colleagues.
#
# Bug 2 — for the same reason, #setup_handover_form's
# `@open_reconciliation = DailyReconciliation.open_for(@branch)` resolved
# Shoubra's OWN currently-open DR (a completely different session), not the
# Nasr City Aug 18 DR the actor came here to close — so its
# TillSession#current_holder was Shoubra's holder, not Anton, producing a
# false "another employee still holds the till" block/error even though
# Anton genuinely is the Nasr City Aug 18 session's current_holder.
#
# Fix: #resolve_branch / a new #target_reconciliation now prefer the
# explicit daily_reconciliation_id (validated via policy_scope +
# DailyReconciliationPolicy#show?) over the actor's own current branch, and
# #branch_colleagues resolves candidates via
# ShiftAssignment#active_on(target's business_date) instead of .current.
RSpec.describe "TillHandovers — historical reconciliation via a temporary ShiftAssignment", type: :request do
  let(:business)   { create(:business) }
  let(:nasr_city)  { create(:branch, business: business, name: "Nasr City") }
  let(:shoubra)    { create(:branch, business: business, name: "Shoubra") }
  let(:cash_pm)    { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: scopes
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # Anton: permanent Shoubra + temporary_coverage Nasr City Aug 17-18 (expired by Aug 20).
  let(:anton) do
    user_with("view_daily_reconciliation", "close_till_session", "accept_till_handover",
              scopes: { "view_daily_reconciliation" => "branch" })
  end

  let(:shoubra_colleague) { user_with("view_daily_reconciliation", "accept_till_handover") }
  let(:nasr_colleague)    { user_with("view_daily_reconciliation", "accept_till_handover") }

  before do
    create(:shift_assignment, business: business, user: anton, branch: shoubra,
           shift: create(:shift, :fixed_time, business: business),
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
    create(:shift_assignment, business: business, user: anton, branch: nasr_city,
           shift: create(:shift, :fixed_time, business: business),
           assignment_kind: "temporary_coverage",
           effective_from: Date.new(2026, 8, 17), effective_to: Date.new(2026, 8, 18),
           reason: "Two-day coverage")

    create(:shift_assignment, business: business, user: shoubra_colleague, branch: shoubra,
           shift: create(:shift, :fixed_time, business: business),
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
    # nasr_colleague's assignment must itself cover Aug 17-18 for the
    # colleague list to include them — proving the list is resolved from the
    # DR's OWN business_date, not "today".
    create(:shift_assignment, business: business, user: nasr_colleague, branch: nasr_city,
           shift: create(:shift, :fixed_time, business: business),
           effective_from: Date.new(2026, 8, 10), effective_to: Date.new(2026, 8, 25))
  end

  let!(:nasr_aug18) do
    dr = DailyReconciliation.create!(
      branch: nasr_city, business: business, state: "open",
      opened_at: Time.new(2026, 8, 18, 8), business_date: Date.new(2026, 8, 18)
    )
    TillSession.create!(daily_reconciliation: dr, current_holder: anton, depositor: anton)
    dr
  end

  before { sign_in anton }

  describe "Bug 1 — the handover employee list" do
    it "does not return Shoubra employees for the Nasr City Aug 18 reconciliation" do
      travel_to Date.new(2026, 8, 20) do
        get new_till_handover_path(daily_reconciliation_id: nasr_aug18.id)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(html_escaped(shoubra_colleague.full_name))
      end
    end

    it "returns the historically-relevant Nasr City employees according to existing eligibility rules" do
      travel_to Date.new(2026, 8, 20) do
        get new_till_handover_path(daily_reconciliation_id: nasr_aug18.id)

        expect(response.body).to include(html_escaped(nasr_colleague.full_name))
      end
    end
  end

  describe "Bug 2 — false 'another employee holds the cashier' block" do
    it "recognizes Anton as the historical holder and does not show the close-blocked message" do
      travel_to Date.new(2026, 8, 20) do
        get new_till_handover_path(daily_reconciliation_id: nasr_aug18.id)

        expect(response.body).not_to include(CGI.escapeHTML(I18n.t("till_handovers.new.close_blocked")))
      end
    end

    it "lets Anton actually close the Aug 18 session" do
      travel_to Date.new(2026, 8, 20) do
        post till_handovers_path, params: {
          till_handover: {
            self_deposit: "1", depositor_type: "self",
            amounts: { cash_pm.id.to_s => { collected_amount: "0", refund_amount: "0" } }
          },
          daily_reconciliation_id: nasr_aug18.id
        }

        expect(response).to redirect_to(finance_daily_reconciliation_path(nasr_aug18))
        expect(nasr_aug18.reload.state).to eq("closed")
        expect(nasr_aug18.till_session.reload.current_holder_id).to be_nil
      end
    end
  end

  describe "existing cashier protection is preserved" do
    it "still blocks closing when another employee genuinely holds the cashier" do
      other_holder = user_with("view_daily_reconciliation", "close_till_session")
      nasr_aug18.till_session.update!(current_holder: other_holder)

      travel_to Date.new(2026, 8, 20) do
        get new_till_handover_path(daily_reconciliation_id: nasr_aug18.id)
        expect(response.body).to include(CGI.escapeHTML(I18n.t("till_handovers.new.close_blocked")))

        post till_handovers_path, params: {
          till_handover: {
            self_deposit: "1", depositor_type: "self",
            amounts: { cash_pm.id.to_s => { collected_amount: "0", refund_amount: "0" } }
          },
          daily_reconciliation_id: nasr_aug18.id
        }

        expect(nasr_aug18.reload.state).to eq("open")
        expect(flash[:alert]).to eq(I18n.t("till_handovers.errors.cannot_close_session"))
      end
    end
  end

  describe "brand-new session creation is still date-scoped to today" do
    it "cannot open a brand-new Nasr City session today via the expired temporary assignment" do
      travel_to Date.new(2026, 8, 20) do
        get new_till_handover_path # no daily_reconciliation_id — a bare "start something" nav

        # Falls back to Anton's own CURRENT branch (Shoubra), never Nasr City.
        expect(anton.effective_branch_on(Date.current)).to eq(shoubra)
        expect(response.body).not_to include(html_escaped(nasr_colleague.full_name))
      end
    end
  end

  describe "the existing Aug 18 session remains accessible and closable throughout" do
    it "the show page and handover modal are both reachable after the assignment has long expired" do
      travel_to Date.new(2026, 9, 1) do
        get finance_daily_reconciliation_path(nasr_aug18)
        expect(response).to have_http_status(:ok)

        get new_till_handover_path(daily_reconciliation_id: nasr_aug18.id)
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(CGI.escapeHTML(I18n.t("till_handovers.new.close_blocked")))
      end
    end
  end
end
