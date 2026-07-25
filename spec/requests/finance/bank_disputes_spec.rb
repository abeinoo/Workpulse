require "rails_helper"

RSpec.describe "Bank Disputes", type: :request do
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

  let(:manager) { user_with("view_daily_reconciliation", "manage_bank_disputes", "view_deposit_verification") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 16),
      reviewed_by: manager, reviewed_at: 1.minute.ago
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: manager.id) }
  let(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: manager,
                        amount: 300, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
  end

  before { sign_in manager }

  describe "creating a dispute" do
    it "opens a new dispute case for a deposit" do
      post finance_bank_disputes_path, params: {
        bank_dispute: {
          till_deposit_id: deposit.id, transaction_date: "2026-07-16", transaction_time: "14:00",
          amount: 300, bank_name: "NBE", terminal_id: "T-001", card_last4: "1234"
        }
      }

      dispute = BankDispute.last
      expect(dispute.status).to eq("new")
      expect(response).to redirect_to(finance_bank_dispute_path(dispute))
    end

    it "re-renders the form on failure" do
      post finance_bank_disputes_path, params: {
        bank_dispute: { till_deposit_id: deposit.id, transaction_date: "2026-07-16", amount: 300 }
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "full lifecycle" do
    let(:dispute) do
      BankDispute.create!(till_deposit: deposit, business: business, branch: branch, opened_by: manager,
                          opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                          amount: 300, bank_name: "NBE", terminal_id: "T-001")
    end

    it "walks New -> Submitted -> Investigating -> Refunded -> Closed" do
      patch submit_to_bank_finance_bank_dispute_path(dispute), params: { bank_ticket_number: "TCK-1" }
      expect(dispute.reload.status).to eq("submitted_to_bank")
      expect(dispute.bank_ticket_number).to eq("TCK-1")

      patch start_investigation_finance_bank_dispute_path(dispute)
      expect(dispute.reload.status).to eq("under_investigation")

      patch refund_finance_bank_dispute_path(dispute), params: { notes: "confirmed by bank" }
      expect(dispute.reload.status).to eq("refunded")

      patch close_finance_bank_dispute_path(dispute)
      expect(dispute.reload.status).to eq("closed")
    end

    it "supports the rejected branch" do
      patch submit_to_bank_finance_bank_dispute_path(dispute)
      patch start_investigation_finance_bank_dispute_path(dispute)
      patch reject_finance_bank_dispute_path(dispute)

      expect(dispute.reload.status).to eq("rejected")
    end

    it "rejects an invalid transition (skipping straight to investigation) via the policy gate" do
      patch start_investigation_finance_bank_dispute_path(dispute)
      expect(response).to redirect_to(root_path)
      expect(dispute.reload.status).to eq("new")
    end
  end

  describe "badge on the deposit" do
    it "shows the Bank Dispute badge on the deposit's show page while open" do
      BankDispute.create!(till_deposit: deposit, business: business, branch: branch, opened_by: manager,
                          opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                          amount: 300, bank_name: "NBE", terminal_id: "T-001", status: "under_investigation")

      get till_deposit_path(deposit)
      expect(response.body).to include(I18n.t("finance.bank_disputes.badge_label"))
    end

    it "hides the badge once the dispute is resolved" do
      BankDispute.create!(till_deposit: deposit, business: business, branch: branch, opened_by: manager,
                          opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                          amount: 300, bank_name: "NBE", terminal_id: "T-001", status: "refunded")

      get till_deposit_path(deposit)
      expect(response.body).not_to include(I18n.t("finance.bank_disputes.badge_label"))
    end

    it "shows the Report Dispute action for a deposit with no bank match" do
      get till_deposit_path(deposit)
      expect(response.body).to include(I18n.t("finance.bank_disputes.report_button"))
    end
  end

  describe "ATM/POS Failed Deposit flow (reported before any TillDeposit exists)" do
    let(:employee) { user_with("close_till_session", "create_till_deposit") }

    let(:atm_dr) do
      DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 17),
        reviewed_by: employee, reviewed_at: 1.minute.ago
      )
    end
    let!(:atm_till_session) { TillSession.create!(daily_reconciliation: atm_dr, depositor_id: employee.id) }
    let!(:atm_session_amount) do
      TillSessionAmount.create!(daily_reconciliation: atm_dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 300, refund_amount: 0)
    end

    it "lets the employee report the problem without creating a TillDeposit or reducing Remaining Cash" do
      sign_in employee

      post finance_bank_disputes_path, params: {
        bank_dispute: {
          daily_reconciliation_id: atm_dr.id, transaction_date: "2026-07-16", transaction_time: "14:00",
          amount: 300, bank_name: "NBE", terminal_id: "ATM-42", card_last4: "1234", atm_location: "Main St branch"
        }
      }

      dispute = BankDispute.last
      expect(dispute.kind).to eq("atm_deposit_failure")
      expect(dispute.daily_reconciliation).to eq(atm_dr)
      expect(dispute.till_deposit).to be_nil
      expect(response).to redirect_to(finance_bank_dispute_path(dispute))

      expect(TillDeposit.count).to eq(0)
      expect(RemainingDepositBalance.count).to eq(0)
      expect(atm_dr.reload.pending_deposit_amount).to eq(300)
    end

    it "blocks an employee from reporting a problem for a reconciliation they are not the depositor of" do
      other = user_with("close_till_session", "create_till_deposit")
      sign_in other

      post finance_bank_disputes_path, params: {
        bank_dispute: {
          daily_reconciliation_id: atm_dr.id, transaction_date: "2026-07-16",
          amount: 300, bank_name: "NBE", terminal_id: "ATM-42", card_last4: "1234"
        }
      }

      expect(BankDispute.count).to eq(0)
      expect(response).to redirect_to(root_path)
    end

    it "shows the DR badge and Open Bank Disputes dashboard count for a no-deposit dispute" do
      BankDispute.create!(daily_reconciliation: atm_dr, business: business, branch: branch, opened_by: employee,
                          opened_at: Time.current, transaction_date: Date.new(2026, 7, 16), kind: "atm_deposit_failure",
                          amount: 300, bank_name: "NBE", terminal_id: "ATM-42", card_last4: "1234")

      sign_in manager
      get finance_daily_reconciliation_path(atm_dr)
      expect(response.body).to include(I18n.t("finance.bank_disputes.dr_badge_label", count: 1))

      get finance_daily_reconciliations_path
      expect(response.body).to match(/#{Regexp.escape(I18n.t("finance.bank_disputes.dashboard_card_title"))}.*?>\s*1\s*</m)
    end

    it "walks the case to Confirmed Successful, then Confirm & Record Deposit creates the real deposit and closes the case" do
      dispute = BankDispute.create!(daily_reconciliation: atm_dr, business: business, branch: branch,
                                    opened_by: employee, opened_at: Time.current,
                                    transaction_date: Date.new(2026, 7, 16), transaction_time: "14:00",
                                    kind: "atm_deposit_failure", amount: 300, bank_name: "NBE",
                                    terminal_id: "ATM-42", card_last4: "1234")

      patch submit_to_bank_finance_bank_dispute_path(dispute), params: { bank_ticket_number: "TCK-9" }
      patch start_investigation_finance_bank_dispute_path(dispute)
      patch confirm_successful_finance_bank_dispute_path(dispute)
      expect(dispute.reload.status).to eq("confirmed_successful")

      patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: cash_pm.id }

      dispute.reload
      expect(dispute.status).to eq("closed")
      expect(dispute.till_deposit).to be_present
      expect(dispute.till_deposit.amount).to eq(300)
      expect(dispute.till_deposit.deposited_by).to eq(employee)
      expect(atm_dr.reload.total_deposited).to eq(300)
    end

    it "supports case management updates (bank ticket number, case note, photos) while open" do
      dispute = BankDispute.create!(daily_reconciliation: atm_dr, business: business, branch: branch,
                                    opened_by: employee, opened_at: Time.current,
                                    transaction_date: Date.new(2026, 7, 16), kind: "atm_deposit_failure",
                                    amount: 300, bank_name: "NBE", terminal_id: "ATM-42", card_last4: "1234")

      patch update_case_finance_bank_dispute_path(dispute), params: {
        bank_ticket_number: "TCK-77", case_note: "Waiting on the bank", case_note_category: "waiting_for_bank"
      }

      expect(dispute.reload.bank_ticket_number).to eq("TCK-77")
      expect(AuditLog.where(auditable: dispute, action: "case_note_added")).to be_present
      expect(response).to redirect_to(finance_bank_dispute_path(dispute))
    end
  end

  describe "Open Disputes dashboard card" do
    it "counts only unresolved disputes and reacts to filters" do
      BankDispute.create!(till_deposit: deposit, business: business, branch: branch, opened_by: manager,
                          opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                          amount: 300, bank_name: "NBE", terminal_id: "T-001", status: "under_investigation")

      get finance_daily_reconciliations_path
      expect(response.body).to include(I18n.t("finance.bank_disputes.dashboard_card_title"))
      expect(response.body).to match(/#{Regexp.escape(I18n.t("finance.bank_disputes.dashboard_card_title"))}.*?>\s*1\s*</m)
    end

    it "drops the count once the dispute is resolved" do
      BankDispute.create!(till_deposit: deposit, business: business, branch: branch, opened_by: manager,
                          opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                          amount: 300, bank_name: "NBE", terminal_id: "T-001", status: "closed")

      get finance_daily_reconciliations_path
      expect(response.body).to match(/#{Regexp.escape(I18n.t("finance.bank_disputes.dashboard_card_title"))}.*?>\s*0\s*</m)
    end
  end
end
