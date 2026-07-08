require "rails_helper"

RSpec.describe "Finance::DailyReconciliations timeline — Branch Review events", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:manager)  { create(:user, :owner, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: manager.id) }

  before { sign_in manager }

  it "shows Branch Review Completed after marking as reviewed" do
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call

    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Branch Review Completed")
  end

  it "shows Branch Review Cancelled after cancelling a review" do
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call
    Finance::DailyReconciliationReviewCanceller.new(dr.id, actor: manager).call

    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Branch Review Cancelled")
  end

  it "shows Branch Review Automatically Cancelled after a Day Close correction invalidates a review" do
    handover = TillHandover.create!(daily_reconciliation: dr, from_user: manager, self_deposit: true,
                                     opening_float_declaration: false, fresha_date: dr.business_date)
    TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 370, refund_amount: 0, kind: "operational")
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call

    Finance::DayCloseEditor.new(dr.reload, actor: manager,
                               amounts: { cash_pm.id => { collected_amount: "470", refund_amount: "0" } },
                               reason: "Recount").call

    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Branch Review Automatically Cancelled")
  end

  it "shows the override event with reason when a deposit is recorded without review" do
    role = business.permission_roles.create!(name: "Super Admin #{SecureRandom.hex(3)}",
                                              permissions: %w[view_daily_reconciliation create_till_deposit
                                                               close_till_session override_review_requirement])
    manager.update_column(:permission_role_id, role.id)

    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 100, refund_amount: 0)

    Finance::TillDepositRecorder.new(
      dr.id, actor: manager,
      params: { payment_method_id: cash_pm.id, amount: "100.00", deposited_at: Time.current.to_s,
                override_review_reason: "Manager unreachable, cashier leaving" }
    ).call

    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Deposit Recorded Without Branch Review")
    expect(response.body).to include("Manager unreachable, cashier leaving")
  end
end
