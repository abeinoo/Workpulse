require "rails_helper"

RSpec.describe "Cancelling a Branch Deposit Review rolls back the deposit, not just the flag", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:employee) { user_with("close_till_session", "create_till_deposit", "view_daily_reconciliation", "view_deposit_verification") }
  let(:manager)  { user_with("review_daily_reconciliation", "verify_daily_reconciliation", "view_daily_reconciliation") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: employee.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 300, refund_amount: 0)
  end

  def record_deposit_text     = I18n.t("finance.daily_reconciliations.show.action_deposit")
  def report_atm_text         = I18n.t("till_deposits.new.report_atm_problem")
  def approved_status_text    = I18n.t("finance.daily_reconciliations.show.review_status_reviewed")
  def cancel_button_text      = I18n.t("finance.daily_reconciliations.show.cancel_review_button")
  def waiting_for_deposit_text = I18n.t("finance.daily_reconciliations.show.waiting_for_deposit_placeholder")

  it "walks Record Deposit -> Review -> Cancel -> Record Again -> Review -> Verify -> Completed" do
    # 1. Depositor records the deposit.
    sign_in employee
    post till_deposits_path, params: {
      till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                      amount: "300.00", deposited_at: Time.current.to_s }
    }
    expect(dr.reload.state).to eq("deposited")
    first_deposit = dr.till_deposits.active.sole

    # 2. Branch Manager reviews (approves) it.
    sign_in manager
    patch mark_reviewed_finance_daily_reconciliation_path(dr)
    expect(dr.reload.reviewed?).to be true

    # 3. Branch Manager cancels the review — full rollback expected.
    patch cancel_review_finance_daily_reconciliation_path(dr)

    dr.reload
    expect(dr.reviewed?).to be false
    expect(dr.reviewed_by_id).to be_nil
    expect(dr.reviewed_at).to be_nil
    expect(dr.deposited?).to be false
    expect(dr.state).to eq("closed")
    expect(first_deposit.reload.voided?).to be true
    expect(dr.till_deposits.active).to be_empty

    # The manager's own view (same request cycle as the redirect target) must
    # show the DR as never-reviewed — no "Deposit Approved" banner, no Cancel
    # Approval button, and the approval section collapsed to the plain
    # "waiting for deposit" placeholder — not left showing the now-stale
    # reviewed/approved state.
    get finance_daily_reconciliation_path(dr)
    expect(response.body).not_to include(approved_status_text)
    expect(response.body).not_to include(cancel_button_text)
    expect(response.body).to include(waiting_for_deposit_text)
    expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.state_waiting_for_branch_deposit_review"))
    expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.state_waiting_for_bank_verification"))

    # Back to "Ready for Deposit" — both actions visible again to the depositor.
    sign_in employee
    get finance_daily_reconciliation_path(dr)
    expect(response.body).to include(record_deposit_text)
    expect(response.body).to include(report_atm_text)

    # The old deposit cannot be reused — the depositor must submit a new one.
    get new_till_deposit_path(daily_reconciliation_id: dr.id)
    expect(response).to have_http_status(:ok)

    # 4. Depositor records the deposit again, from scratch.
    post till_deposits_path, params: {
      till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                      amount: "300.00", deposited_at: Time.current.to_s }
    }
    expect(dr.reload.state).to eq("deposited")
    second_deposit = dr.till_deposits.active.sole
    expect(second_deposit.id).not_to eq(first_deposit.id)

    # Bank verification must be blocked until the NEW deposit is reviewed —
    # verified through the actual HTTP endpoint, not just the service object.
    sign_in manager
    patch verify_finance_daily_reconciliation_path(dr), params: { notes: "" }
    expect(dr.reload.verified?).to be false

    verify_result = Finance::DailyReconciliationVerifier.new(dr.id, actor: manager).call
    expect(verify_result.ok?).to be false
    expect(verify_result.error).to eq(I18n.t("finance.daily_reconciliations.errors.verify_requires_deposit_review"))

    # 5. Branch Manager reviews the new deposit.
    patch mark_reviewed_finance_daily_reconciliation_path(dr)
    expect(dr.reload.reviewed?).to be true

    # 6. Bank verification now proceeds -> Completed.
    patch verify_finance_daily_reconciliation_path(dr), params: { notes: "" }
    expect(dr.reload.verified?).to be true
  end
end
