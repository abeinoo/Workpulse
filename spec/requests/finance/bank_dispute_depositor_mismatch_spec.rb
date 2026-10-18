require "rails_helper"

# Root cause of "confirmed dispute won't register as a deposit, index stays
# stuck on Awaiting Deposit": Finance::BankDisputes::DepositConfirmer always
# attributes the resulting TillDeposit to dispute.opened_by (not the
# confirming accountant) — see that service's own comment. If the till's
# depositor has since changed, Finance::TillDepositRecorder rejects the
# attempt and NOTHING is created; the index is then correctly still showing
# "Awaiting Deposit" because no deposit genuinely exists yet. This spec
# covers the fix: surfacing that blocker clearly on the dispute page (instead
# of only after a failed submit) with a one-click path — reusing the
# existing assign_depositor route/service — to resolve it and proceed.
RSpec.describe "Bank Dispute — depositor mismatch blocking deposit registration", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def build_dr(expected_amount:, depositor:)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: depositor.id)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: expected_amount, refund_amount: 0)
    dr
  end

  let(:reporter)   { user_with("view_daily_reconciliation", "create_till_deposit", "close_till_session") }
  let(:accountant) do
    user_with("view_daily_reconciliation", "manage_bank_disputes", "settle_remaining_deposit_balance",
              "verify_daily_reconciliation", "view_session_totals", "view_all_employee_reconciliation_summary")
  end

  def confirm_successful!(dispute)
    %w[submit_to_bank start_investigation confirm_successful].each do |route|
      patch "/finance/bank_disputes/#{dispute.id}/#{route}", params: {}
    end
    dispute.reload
  end

  it "warns on the dispute page and blocks confirm_deposit once the depositor has moved on, then unblocks after reassigning" do
    dr = build_dr(expected_amount: 12_815, depositor: reporter)
    dispute = BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: reporter,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: 12_750, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )

    other_depositor = user_with("close_till_session")
    dr.till_session.update!(depositor_id: other_depositor.id)

    sign_in accountant
    confirm_successful!(dispute)
    expect(dispute.status).to eq("confirmed_successful")
    expect(dispute.blocked_by_depositor_mismatch?).to be true

    get finance_bank_dispute_path(dispute)
    expect(response.body).to include(I18n.t("finance.bank_disputes.show.depositor_mismatch_title"))
    reassign_form_target = assign_depositor_finance_daily_reconciliation_path(dr)
    expect(response.body).to include(reassign_form_target)

    # Submitting Confirm Deposit anyway still fails cleanly (unchanged, existing guard).
    patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: cash_pm.id }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(dispute.reload.till_deposit).to be_nil

    # One click via the existing assign_depositor route resolves it.
    patch reassign_form_target, params: { depositor_id: reporter.id }
    expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
    expect(dr.till_session.reload.depositor_id).to eq(reporter.id)

    get finance_bank_dispute_path(dispute)
    expect(response.body).not_to include(I18n.t("finance.bank_disputes.show.depositor_mismatch_title"))

    patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: cash_pm.id }
    expect(response).to redirect_to(finance_bank_dispute_path(dispute))
    dispute.reload
    expect(dispute.till_deposit).to be_present
    expect(dispute.till_deposit.amount).to eq(12_750)

    rdb = dr.reload.remaining_deposit_balances.open.sole
    expect(rdb.remaining_amount).to eq(65)

    get finance_daily_reconciliations_path
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css(".dr-card").text).to include(I18n.t("finance.daily_reconciliations.index.workspace.workflow.settle_action"))
  end

  it "does not warn when opened_by is still the current depositor (normal, unblocked case)" do
    dr = build_dr(expected_amount: 12_815, depositor: reporter)
    dispute = BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: reporter,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: 12_750, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )

    sign_in accountant
    confirm_successful!(dispute)
    expect(dispute.blocked_by_depositor_mismatch?).to be false

    get finance_bank_dispute_path(dispute)
    expect(response.body).not_to include(I18n.t("finance.bank_disputes.show.depositor_mismatch_title"))
  end

  it "does not warn once opened_by is the business owner (always allowed regardless of till depositor)" do
    owner = create(:user, :owner, business: business)
    dr = build_dr(expected_amount: 500, depositor: reporter)
    dispute = BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: owner,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: 500, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )

    sign_in accountant
    confirm_successful!(dispute)
    expect(dispute.blocked_by_depositor_mismatch?).to be false
  end

  it "shows a no-permission notice instead of the reassign form for a user without assign_depositor authority" do
    limited_accountant = user_with("view_daily_reconciliation", "manage_bank_disputes",
                                   "settle_remaining_deposit_balance")
    dr = build_dr(expected_amount: 12_815, depositor: reporter)
    dispute = BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: reporter,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: 12_750, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )
    dr.till_session.update!(depositor_id: user_with("close_till_session").id)

    sign_in limited_accountant
    confirm_successful!(dispute)

    get finance_bank_dispute_path(dispute)
    expect(response.body).to include(I18n.t("finance.bank_disputes.show.depositor_mismatch_title"))
    expect(response.body).to include(html_escaped(I18n.t("finance.bank_disputes.show.depositor_mismatch_no_permission",
                                                         opened_by: reporter.full_name)))
    expect(response.body).not_to include(assign_depositor_finance_daily_reconciliation_path(dr))
  end
end
