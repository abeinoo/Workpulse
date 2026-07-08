require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — Review Status card", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:manager)  { user_with("view_daily_reconciliation", "review_daily_reconciliation") }
  let(:no_perm)  { user_with("view_daily_reconciliation") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: manager.id) }

  it "shows Pending Review with a Mark as Reviewed button for a permissioned user" do
    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Pending Review")
    expect(response.body).to include("Mark as Reviewed")
  end

  it "does not show the Mark as Reviewed button for a user without the permission" do
    sign_in no_perm
    get finance_daily_reconciliation_path(dr)

    expect(response.body).not_to include("Mark as Reviewed")
  end

  it "shows Reviewed / Reviewed By / Reviewed At with a Cancel Review button once reviewed" do
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call

    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Reviewed By")
    expect(response.body).to include("Reviewed At")
    expect(response.body).to include(manager.full_name)
    expect(response.body).to include("Cancel Review")
  end

  it "hides the Cancel Review button once a deposit exists" do
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call
    cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
    dr.till_deposits.create!(payment_method: cash_pm, deposited_by: manager, amount: 50, deposited_at: Time.current)

    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include(manager.full_name)
    expect(response.body).not_to include("Cancel Review")
  end

  it "shows Review Invalidated when a prior review was automatically cancelled" do
    handover = TillHandover.create!(daily_reconciliation: dr, from_user: manager, self_deposit: true,
                                     opening_float_declaration: false, fresha_date: dr.business_date)
    cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
    TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 370, refund_amount: 0, kind: "operational")
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call
    Finance::DayCloseEditor.new(dr.reload, actor: manager,
                               amounts: { cash_pm.id => { collected_amount: "470", refund_amount: "0" } },
                               reason: "Recount").call

    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Review Invalidated")
    expect(response.body).to include("Mark as Reviewed")
  end
end
