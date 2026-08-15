require "rails_helper"

RSpec.describe "TillHandovers#new/#create — administrative actors without a current branch assignment",
               type: :request do
  let(:business)      { create(:business) }
  let(:branch)        { create(:branch, business: business) }
  let(:other_branch)  { create(:branch, business: business) }
  let(:cash_pm)       { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: scopes
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def open_dr_for(target_branch, holder:)
    dr = DailyReconciliation.create!(
      branch: target_branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: dr, current_holder: holder)
    dr
  end

  let(:cashier) { user_with("view_daily_reconciliation", "accept_till_handover") }
  let!(:dr)     { open_dr_for(branch, holder: cashier) }

  def handover_params
    { till_handover: { to_user_id: cashier.id, notes: "shift end",
                        amounts: { cash_pm.id.to_s => { collected_amount: "100", refund_amount: "0" } } } }
  end

  context "Super Admin (business owner) with no current shift assignment" do
    let(:owner) { create(:user, :owner, business: business) }

    it "can open the handover/return form for a branch's reconciliation" do
      sign_in owner
      get new_till_handover_path(daily_reconciliation_id: dr.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("till_handovers.errors.no_branch"))
    end

    it "can submit the cashier handover (with refund amounts) for that branch" do
      sign_in owner
      post till_handovers_path, params: handover_params.merge(daily_reconciliation_id: dr.id)

      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      follow_redirect!
      expect(response.body).not_to include(I18n.t("till_handovers.errors.no_branch"))
      expect(dr.till_handovers.count).to eq(1)
    end
  end

  context "Area Manager with close_till_session permission and no shift assignment" do
    let(:area_manager) { user_with("view_daily_reconciliation", "close_till_session",
                                   scopes: { "view_daily_reconciliation" => "area" }) }

    before { branch.update!(area_manager: area_manager) }

    it "can perform the handover for a branch within their authorized area" do
      sign_in area_manager
      post till_handovers_path, params: handover_params.merge(daily_reconciliation_id: dr.id)

      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(dr.till_handovers.count).to eq(1)
    end

    it "is rejected for a branch outside their authorized area" do
      other_cashier = user_with("view_daily_reconciliation", "accept_till_handover")
      other_dr = open_dr_for(other_branch, holder: other_cashier)

      sign_in area_manager
      post till_handovers_path, params: {
        till_handover: { to_user_id: other_cashier.id,
                          amounts: { cash_pm.id.to_s => { collected_amount: "100", refund_amount: "0" } } },
        daily_reconciliation_id: other_dr.id
      }

      expect(response).to redirect_to(finance_daily_reconciliations_path)
      expect(flash[:alert]).to eq(I18n.t("till_handovers.errors.no_branch"))
      expect(other_dr.till_handovers.count).to eq(0)
    end
  end

  it "rejects a normal user without close_till_session, even with a daily_reconciliation_id" do
    unpermitted = user_with("view_daily_reconciliation")

    sign_in unpermitted
    get new_till_handover_path(daily_reconciliation_id: dr.id)

    expect(response).to redirect_to(root_path).or redirect_to(finance_daily_reconciliations_path)
  end

  it "does not surface the 'not assigned to a branch' error for a permitted user with no shift assignment" do
    accountant = user_with("view_daily_reconciliation", "close_till_session",
                           scopes: { "view_daily_reconciliation" => "business" })

    sign_in accountant
    post till_handovers_path, params: handover_params.merge(daily_reconciliation_id: dr.id)

    expect(flash[:alert]).not_to eq(I18n.t("till_handovers.errors.no_branch"))
  end

  it "still blocks a permitted user (business scope) with no daily_reconciliation_id and no shift assignment" do
    accountant = user_with("view_daily_reconciliation", "close_till_session",
                           scopes: { "view_daily_reconciliation" => "business" })

    sign_in accountant
    post till_handovers_path, params: handover_params

    expect(response).to redirect_to(finance_daily_reconciliations_path)
    expect(flash[:alert]).to eq(I18n.t("till_handovers.errors.no_branch"))
  end

  context "existing branch-assigned cashier flow" do
    it "continues to work exactly as before, ignoring any stray daily_reconciliation_id param" do
      create(:shift_assignment, business: business, user: cashier, branch: branch)
      # cashier is themselves the current holder here; use a distinct sender
      sender = user_with("view_daily_reconciliation", "close_till_session")
      create(:shift_assignment, business: business, user: sender, branch: branch)
      dr.till_session.update!(current_holder: sender)

      sign_in sender
      post till_handovers_path, params: {
        till_handover: { to_user_id: cashier.id,
                          amounts: { cash_pm.id.to_s => { collected_amount: "100", refund_amount: "0" } } },
        daily_reconciliation_id: other_branch.id
      }

      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(dr.till_handovers.where(from_user: sender).count).to eq(1)
    end
  end
end
