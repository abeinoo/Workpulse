require "rails_helper"

# Regression coverage for: the "Create Daily Reconciliation" branch picker
# (accessible_branches_for_dr) and the create-time branch authorization
# (resolve_branch) both resolved a non-manager's accessible branches from
# current_user.effective_branch_on(Date.current) — TODAY's single winning
# assignment — regardless of which business_date the user actually selected
# on the form. This meant:
#   1. The branch list shown on GET /new never changed when the date changed.
#   2. Even POSTing an explicitly historical business_date with a branch_id
#      the user WAS legitimately shift-assigned to on that date (but not
#      today) was rejected as "invalid_branch", because #resolve_branch
#      validated against today's branches, not the selected date's.
#
# Fix: accessible_branches_for_dr(date) / resolve_branch(date) now resolve a
# non-manager's branches from EVERY ShiftAssignment covering that specific
# date (ShiftAssignment#active_on(date)) — permanent or temporary — instead
# of "today's effective branch." Selecting a date is an input to
# authorization, never a bypass of it: a branch only appears if the user
# actually had (or has) a ShiftAssignment covering that exact date.
RSpec.describe "Finance::DailyReconciliations#new / #create — date-aware branch picker", type: :request do
  let(:business)  { create(:business) }
  let(:nasr_city) { create(:branch, business: business, name: "Nasr City") }
  let(:shoubra)   { create(:branch, business: business, name: "Shoubra") }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: scopes
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # An ordinary Reception/non-manager employee — no management scope, just a
  # cashier-level permission set with a permanent Shoubra assignment.
  let(:reception) do
    user_with("view_daily_reconciliation", "create_till_session", "close_till_session",
              scopes: { "view_daily_reconciliation" => "branch" })
  end

  before do
    create(:shift_assignment, business: business, user: reception, branch: shoubra,
           shift: create(:shift, :fixed_time, business: business),
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
  end

  describe "A — a Reception (non-manager) user can see and select the date field" do
    it "renders the business_date field on the create form" do
      sign_in reception
      get new_finance_daily_reconciliation_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="business_date"')
    end
  end

  describe "B — Reception can create a historical DR for a date their assignment authorizes" do
    it "shows Shoubra in the picker and succeeds for a past date" do
      sign_in reception
      past_date = Date.new(2026, 8, 10)

      get new_finance_daily_reconciliation_path, params: { business_date: past_date.iso8601 }
      expect(response.body).to include(shoubra.name)

      post finance_daily_reconciliations_path,
           params: { branch_id: shoubra.id, business_date: past_date.iso8601 }

      dr = DailyReconciliation.order(:created_at).last
      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(dr.branch).to eq(shoubra)
      expect(dr.business_date).to eq(past_date)
      expect(dr.state).to eq("closed")
    end
  end

  describe "C — Reception cannot create a historical DR for a branch they were never assigned to" do
    it "rejects an explicit branch_id for a branch outside the picker" do
      sign_in reception
      past_date = Date.new(2026, 8, 10)

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: nasr_city.id, business_date: past_date.iso8601 }
      }.not_to change(DailyReconciliation, :count)

      expect(response).to redirect_to(new_finance_daily_reconciliation_path)
      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.invalid_branch"))
    end
  end

  describe "D — Reception cannot select/create a future date" do
    it "GET /new falls back silently to today rather than honoring a future date" do
      sign_in reception
      today = BusinessDay.current(context: business)
      future = today + 5.days

      get new_finance_daily_reconciliation_path, params: { business_date: future.iso8601 }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("value=\"#{today.iso8601}\"")
    end

    it "POST /create rejects a future date outright" do
      sign_in reception
      future = BusinessDay.current(context: business) + 5.days

      expect {
        post finance_daily_reconciliations_path,
             params: { branch_id: shoubra.id, business_date: future.iso8601 }
      }.not_to change(DailyReconciliation, :count)

      expect(response).to redirect_to(new_finance_daily_reconciliation_path)
      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.future_date_not_allowed"))
    end
  end

  describe "E — existing current-day behavior is unchanged for Reception" do
    it "creates today's session as open, using today's own branch" do
      sign_in reception
      today = BusinessDay.current(context: business)

      post finance_daily_reconciliations_path,
           params: { branch_id: shoubra.id, business_date: today.iso8601 }

      dr = DailyReconciliation.order(:created_at).last
      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(dr.state).to eq("open")
      expect(dr.business_date).to eq(today)
    end
  end

  describe "Anton — permanent Shoubra + temporary Nasr City Aug 17-18" do
    let(:anton) do
      user_with("view_daily_reconciliation", "create_till_session", "close_till_session",
                scopes: { "view_daily_reconciliation" => "branch" })
    end

    before do
      create(:shift_assignment, business: business, user: anton, branch: shoubra,
             shift: create(:shift, :fixed_time, business: business),
             effective_from: Date.new(2026, 1, 1), effective_to: nil)
      create(:shift_assignment, business: business, user: anton, branch: nasr_city,
             shift: create(:shift, :fixed_time, business: business),
             assignment_kind: "temporary_coverage",
             effective_from: Date.new(2026, 8, 17), effective_to: Date.new(2026, 8, 18),
             reason: "Two-day coverage")
      sign_in anton
    end

    describe "F — Aug 18 Nasr City works" do
      it "shows both Shoubra and Nasr City in the picker, and Nasr City creation succeeds" do
        get new_finance_daily_reconciliation_path, params: { business_date: "2026-08-18" }
        expect(response.body).to include(shoubra.name)
        expect(response.body).to include(nasr_city.name)

        post finance_daily_reconciliations_path,
             params: { branch_id: nasr_city.id, business_date: "2026-08-18" }

        dr = DailyReconciliation.order(:created_at).last
        expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
        expect(dr.branch).to eq(nasr_city)
        expect(dr.business_date).to eq(Date.new(2026, 8, 18))
      end
    end

    describe "G — Aug 19 Nasr City does not work" do
      it "excludes Nasr City from the picker and rejects an explicit attempt" do
        get new_finance_daily_reconciliation_path, params: { business_date: "2026-08-19" }
        expect(response.body).to include(shoubra.name)
        expect(response.body).not_to include(nasr_city.name)

        expect {
          post finance_daily_reconciliations_path,
               params: { branch_id: nasr_city.id, business_date: "2026-08-19" }
        }.not_to change(DailyReconciliation, :count)

        expect(response).to redirect_to(new_finance_daily_reconciliation_path)
        expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.invalid_branch"))
      end
    end

    describe "H — Aug 20 brand-new Nasr City creation still does not work after expiration" do
      it "excludes Nasr City from today's picker and rejects an explicit attempt" do
        travel_to Date.new(2026, 8, 20) do
          get new_finance_daily_reconciliation_path
          expect(response.body).to include(shoubra.name)
          expect(response.body).not_to include(nasr_city.name)

          expect {
            post finance_daily_reconciliations_path,
                 params: { branch_id: nasr_city.id, business_date: Date.current.iso8601 }
          }.not_to change(DailyReconciliation, :count)

          expect(response).to redirect_to(new_finance_daily_reconciliation_path)
          expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.invalid_branch"))
        end
      end
    end

    describe "I — a second attempt at an existing (branch, selected_date) redirects to THAT exact DR" do
      it "redirects to the Aug 18 Nasr City DR, not today's or any other DR" do
        travel_to Date.new(2026, 8, 20) do
          # An unrelated DR exists for today at Shoubra, to prove it's ignored.
          today_dr = DailyReconciliation.create!(branch: shoubra, business: business, state: "open",
                                                  opened_at: Time.current,
                                                  business_date: BusinessDay.current(context: business))
          TillSession.create!(daily_reconciliation: today_dr)

          post finance_daily_reconciliations_path,
               params: { branch_id: nasr_city.id, business_date: "2026-08-18" }
          first_dr = DailyReconciliation.find_by!(branch: nasr_city, business_date: Date.new(2026, 8, 18))

          expect {
            post finance_daily_reconciliations_path,
                 params: { branch_id: nasr_city.id, business_date: "2026-08-18" }
          }.not_to change(DailyReconciliation, :count)

          expect(response).to redirect_to(finance_daily_reconciliation_path(first_dr))
          expect(response).not_to redirect_to(finance_daily_reconciliation_path(today_dr))
          expect(flash[:notice]).to eq(I18n.t("finance.daily_reconciliations.errors.dr_exists_for_date"))
        end
      end
    end
  end
end
