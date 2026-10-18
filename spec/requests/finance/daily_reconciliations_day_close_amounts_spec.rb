require "rails_helper"

RSpec.describe "Finance::DailyReconciliations day close editing", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:no_perm)  { create(:user, business: business) }

  let!(:manager) do
    role = PermissionRole.find_or_create_by!(business: business, name: "DR Manager #{business.id}") do |r|
      r.permissions       = %w[view_daily_reconciliation edit_day_close_amounts]
      r.permission_scopes = {
        "view_daily_reconciliation" => "business_wide",
        "edit_day_close_amounts"   => "business_wide"
      }
    end
    create(:user, business: business, permission_role: role)
  end

  let(:cash_pm) do
    PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
  end
  let(:visa_pm) do
    PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
  end

  let(:dr) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      closed_at:     Time.current,
      business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  let!(:closing_handover) do
    TillHandover.create!(
      daily_reconciliation:      dr,
      from_user:                 actor,
      self_deposit:              true,
      opening_float_declaration: false,
      fresha_date:               dr.business_date
    )
  end

  let!(:cash_amount) do
    TillHandoverAmount.create!(till_handover: closing_handover, payment_method: cash_pm,
                                payment_method_name: cash_pm.name, collected_amount: 7_225,
                                refund_amount: 0, kind: "operational")
  end
  let!(:visa_amount) do
    TillHandoverAmount.create!(till_handover: closing_handover, payment_method: visa_pm,
                                payment_method_name: visa_pm.name, collected_amount: 4_801,
                                refund_amount: 0, kind: "operational")
  end

  describe "GET /finance/daily_reconciliations/:id/edit_day_close_amounts" do
    it "renders the form pre-filled with the current amounts for an authorized manager" do
      sign_in manager
      get edit_day_close_amounts_finance_daily_reconciliation_path(dr)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("7225")
      expect(response.body).to include("4801")
    end

    it "denies a user without the permission" do
      sign_in no_perm
      get edit_day_close_amounts_finance_daily_reconciliation_path(dr)

      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "PATCH /finance/daily_reconciliations/:id/update_day_close_amounts" do
    def submit(reason: "Cashier mistyped the cash amount")
      patch update_day_close_amounts_finance_daily_reconciliation_path(dr),
            params: {
              amounts: {
                cash_pm.id => { collected_amount: "7250", refund_amount: "0" },
                visa_pm.id => { collected_amount: "4801", refund_amount: "0" }
              },
              reason: reason
            }
    end

    it "updates the amounts, recomputes Branch Totals, and logs the timeline event" do
      sign_in manager
      submit

      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(cash_amount.reload.collected_amount).to eq(7_250)
      expect(dr.session_amounts.find_by(payment_method: cash_pm).collected_amount).to eq(7_250)

      follow_redirect!
      expect(response.body).to include(html_escaped(I18n.t("finance.daily_reconciliations.show.timeline.day_close_edited",
                                                           actor: manager.full_name)))
    end

    # The timeline names the editor; a name with an apostrophe is rendered
    # HTML-escaped (CI run #265 failed only because Faker generated "O'Keefe").
    it "logs the timeline event for an editor whose name contains an apostrophe" do
      manager.update!(last_name: "O'Keefe")
      sign_in manager
      submit
      follow_redirect!

      event = I18n.t("finance.daily_reconciliations.show.timeline.day_close_edited", actor: manager.full_name)
      expect(response.body).to include(html_escaped(event))
      expect(response.body).to include("O&#39;Keefe")
    end

    it "requires a reason" do
      sign_in manager
      submit(reason: "")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(cash_amount.reload.collected_amount).to eq(7_225)
    end

    it "blocks the edit once the DR has been deposited" do
      dr.update_columns(state: "deposited")
      sign_in manager
      submit

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.errors.cannot_edit_after_deposit"))
      expect(cash_amount.reload.collected_amount).to eq(7_225)
    end

    it "blocks the edit once the DR has been verified" do
      dr.update_columns(state: "verified", verified_at: Time.current, verified_by_id: actor.id)
      sign_in manager
      submit

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.errors.cannot_edit_after_verification"))
      expect(cash_amount.reload.collected_amount).to eq(7_225)
    end

    it "denies a user without the permission" do
      sign_in no_perm
      submit

      expect(response).not_to have_http_status(:ok)
      expect(cash_amount.reload.collected_amount).to eq(7_225)
    end
  end
end
