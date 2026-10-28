require "rails_helper"

RSpec.describe DailyReconciliation, "#workflow_progress" do
  include Rails.application.routes.url_helpers

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

  let(:no_perms_user) { create(:user, business: business) }

  def make_dr(state:, business_date: Date.current, verified: false, depositor: nil)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: state,
      opened_at: 1.hour.ago, closed_at: (Time.current if state != "open" && state != "waiting_for_opening"),
      business_date: business_date,
      verified_by: (depositor if verified), verified_at: (1.minute.ago if verified)
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: depositor&.id) if depositor || state != "waiting_for_opening"
    dr
  end

  def collect_cash!(dr, amount)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                              payment_method_name: cash_pm.name, collected_amount: amount, refund_amount: 0)
  end

  def deposit!(dr, amount:, depositor:)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: depositor,
                        amount: amount, deposited_at: Time.current)
  end

  def keys_of(result) = result[:steps].map { |s| s[:key] }
  def current_key(result) = result[:steps].find { |s| !s[:complete] }&.dig(:key)

  it "returns all 8 steps in the fixed order — no separate Deposit Review step" do
    dr = make_dr(state: "waiting_for_opening", business_date: Date.yesterday)

    expect(keys_of(dr.workflow_progress(no_perms_user))).to eq(
      %i[opening_float close_handover deposit sales_import pos_import bank_statement bank_matching documentation]
    )
  end

  # ── Step 1: Opening Float ──────────────────────────────────────────────
  describe "step 1 — opening_float" do
    let(:dr) { make_dr(state: "waiting_for_opening", business_date: Date.yesterday) }

    it "is the current step and returns its action for a user with cashier permission" do
      user = user_with("create_till_session", "close_till_session")

      result = dr.workflow_progress(user)

      expect(current_key(result)).to eq(:opening_float)
      expect(result[:action]).to eq(
        label: "Receive Opening Balance", path: finance_daily_reconciliation_path(dr), style: "btn btn-primary btn-sm"
      )
    end

    it "returns no action for a user without cashier permission — but does not cascade to a later step" do
      result = dr.workflow_progress(no_perms_user)

      expect(current_key(result)).to eq(:opening_float)
      expect(result[:action]).to be_nil
    end

    it "returns no action when the float isn't receivable yet (business day hasn't reached it)" do
      future_dr = make_dr(state: "waiting_for_opening", business_date: Date.tomorrow + 5)
      user = user_with("create_till_session", "close_till_session")

      result = future_dr.workflow_progress(user)

      expect(current_key(result)).to eq(:opening_float)
      expect(result[:action]).to be_nil
    end

    it "marks every later step incomplete too, even though their own individual conditions might coincidentally hold" do
      result = dr.workflow_progress(no_perms_user)

      expect(result[:steps].map { |s| s[:complete] }).to eq(Array.new(DailyReconciliation::WORKFLOW_STEPS.size, false))
    end
  end

  # ── Step 2: Close / Handover ───────────────────────────────────────────
  describe "step 2 — close_handover" do
    let(:dr) { make_dr(state: "open") }

    it "is the current step once opened, and links to the DR show page" do
      result = dr.workflow_progress(no_perms_user)

      expect(current_key(result)).to eq(:close_handover)
      expect(result[:action]).to eq(
        label: "Close / Handover Cashier", path: finance_daily_reconciliation_path(dr), style: "btn btn-primary btn-sm"
      )
    end
  end

  # ── Step 3: Deposit ─────────────────────────────────────────────────────
  describe "step 3 — deposit" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "closed", depositor: depositor) }

    it "returns Record Deposit for the assigned depositor" do
      depositor.update_column(
        :permission_role_id,
        business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: %w[create_till_deposit close_till_session],
                                          permission_scopes: { "create_till_deposit" => "business_wide", "close_till_session" => "business_wide" }).id
      )

      result = dr.workflow_progress(depositor)

      expect(current_key(result)).to eq(:deposit)
      expect(result[:action]).to eq(
        label: "Record Deposit", path: new_till_deposit_path(daily_reconciliation_id: dr.id), style: "btn btn-primary btn-sm"
      )
    end

    it "is complete as soon as any deposit is recorded — an OPEN RemainingDepositBalance shortfall must never reopen it" do
      # RDB is a separate, independently-tracked, append-only ledger (open ->
      # settled | written_off) that a DR can be fully reviewed/verified while
      # still carrying — it must never gate the sequential Deposit step.
      dep = deposit!(dr, amount: 60, depositor: depositor)
      # Finance::TillDepositRecorder flips state closed -> deposited atomically
      # on the first deposit; simulate that here since this test writes the
      # TillDeposit directly.
      dr.update_columns(state: "deposited")
      RemainingDepositBalance.create!(
        daily_reconciliation: dr, till_deposit: dep, responsible_user: depositor, created_by: depositor,
        business: business, branch: branch, amount: 40, remaining_amount: 40, status: "open"
      )

      result = dr.workflow_progress(no_perms_user)

      expect(current_key(result)).not_to eq(:deposit)
      expect(result[:steps].find { |s| s[:key] == :deposit }[:complete]).to be true
    end
  end

  # ── Regression: reported "impossible" card state ────────────────────────
  describe "regression — status badge and Next Step must never disagree" do
    it "never shows the Deposit action once the DR is already deposited (badge = awaiting accounting approval), even with an open RDB shortfall" do
      depositor = create(:user, business: business)
      dr = make_dr(state: "deposited", depositor: depositor)
      dep = deposit!(dr, amount: 60, depositor: depositor)
      RemainingDepositBalance.create!(
        daily_reconciliation: dr, till_deposit: dep, responsible_user: depositor, created_by: depositor,
        business: business, branch: branch, amount: 40, remaining_amount: 40, status: "open"
      )

      expect(dr.lifecycle_stage).to eq(:awaiting_verification)

      result = dr.workflow_progress(no_perms_user, sales_imported: false)

      expect(result[:steps].find { |s| s[:key] == :deposit }[:complete]).to be true
      expect(current_key(result)).to eq(:sales_import)
      expect(result[:action][:label]).to eq("Verify Sales Transactions")
    end
  end

  # ── Step 4: Sales Import — reachable directly after Deposit, no Deposit
  #    Review approval step in between ─────────────────────────────────────
  describe "step 4 — sales_import" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "is current and actionable (ungated) when sales_imported is false" do
      result = dr.workflow_progress(no_perms_user, sales_imported: false)

      expect(current_key(result)).to eq(:sales_import)
      expect(result[:action]).to eq(
        label: "Verify Sales Transactions", path: finance_sales_imports_path, style: "btn btn-primary btn-sm"
      )
    end

    it "is complete once sales_imported is true, advancing to the next step" do
      result = dr.workflow_progress(no_perms_user, sales_imported: true)

      expect(current_key(result)).not_to eq(:sales_import)
      expect(result[:steps].find { |s| s[:key] == :sales_import }[:complete]).to be true
    end
  end

  # ── Step 5: POS Import ──────────────────────────────────────────────────
  describe "step 5 — pos_import" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Import POS Transactions for a user with manage_pos_import" do
      user = user_with("manage_pos_import", "view_pos_import")

      result = dr.workflow_progress(user, sales_imported: true, pos_imported: false)

      expect(current_key(result)).to eq(:pos_import)
      expect(result[:action]).to eq(
        label: "Import POS Transactions", path: new_finance_pos_import_path, style: "btn btn-primary btn-sm"
      )
    end

    it "returns no action for a user without manage_pos_import" do
      result = dr.workflow_progress(no_perms_user, sales_imported: true, pos_imported: false)

      expect(current_key(result)).to eq(:pos_import)
      expect(result[:action]).to be_nil
    end

    it "is complete once pos_imported is true, advancing to the next step" do
      result = dr.workflow_progress(no_perms_user, sales_imported: true, pos_imported: true)

      expect(current_key(result)).not_to eq(:pos_import)
      expect(result[:steps].find { |s| s[:key] == :pos_import }[:complete]).to be true
    end
  end

  def step(result, key) = result[:steps].find { |s| s[:key] == key }

  # ── Step 6: Bank Statement Import ───────────────────────────────────────
  describe "step 6 — bank_statement (import)" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Import Bank Statement when bank_status is waiting_for_bank_statement" do
      user = user_with("import_bank_statement", "view_deposit_verification")

      result = dr.workflow_progress(user, bank_status: "waiting_for_bank_statement", sales_imported: true, pos_imported: true)

      expect(current_key(result)).to eq(:bank_statement)
      expect(step(result, :bank_statement)[:complete]).to be false
      expect(result[:action]).to eq(
        label: "Import Bank Statement", path: new_finance_bank_statement_path, style: "btn btn-primary btn-sm"
      )
    end

    it "is not complete without bank status data (no applicable import)" do
      result = dr.workflow_progress(no_perms_user, bank_status: nil, sales_imported: true, pos_imported: true)

      expect(step(result, :bank_statement)[:complete]).to be false
      expect(current_key(result)).to eq(:bank_statement)
    end

    (DailyReconciliation::BANK_STATUSES_AFTER_IMPORT).each do |status|
      it "is complete for bank_status=#{status}, even while POS Import is incomplete", :aggregate_failures do
        result = dr.workflow_progress(no_perms_user, bank_status: status, sales_imported: true, pos_imported: false)

        expect(step(result, :bank_statement)[:complete]).to be true
        expect(step(result, :pos_import)[:complete]).to be false
        expect(current_key(result)).to eq(:pos_import)
      end
    end

    it "is complete while matching is still pending, and Next Step moves on to matching", :aggregate_failures do
      result = dr.workflow_progress(no_perms_user, bank_status: "waiting_for_matching", sales_imported: true, pos_imported: true)

      expect(step(result, :bank_statement)[:complete]).to be true
      expect(step(result, :bank_matching)[:complete]).to be false
      expect(current_key(result)).to eq(:bank_matching)
    end
  end

  # ── Step 7: Bank Matching (matching + dispute resolution) ───────────────
  describe "step 7 — bank_matching" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "is not reachable until pos_import is complete, even if bank_status is otherwise clean" do
      result = dr.workflow_progress(no_perms_user, bank_status: "completed", sales_imported: true, pos_imported: false)

      expect(current_key(result)).to eq(:pos_import)
      expect(step(result, :bank_matching)[:complete]).to be false
    end

    it "is never complete while the statement is not imported yet" do
      result = dr.workflow_progress(no_perms_user, bank_status: "waiting_for_bank_statement", sales_imported: true, pos_imported: true)

      expect(step(result, :bank_matching)[:complete]).to be false
      expect(current_key(result)).to eq(:bank_statement)
    end

    DailyReconciliation::BANK_MATCHING_STATUSES.each do |status|
      it "is the current step with the matching action for bank_status=#{status}" do
        user = user_with("manual_match_deposits", "verify_deposits", "view_deposit_verification")

        result = dr.workflow_progress(user, bank_status: status, sales_imported: true, pos_imported: true)

        expect(current_key(result)).to eq(:bank_matching)
        expect(result[:action]).to eq(
          label: "Match Bank Deposits", path: finance_daily_reconciliation_path(dr, anchor: "bank-deposits"),
          style: "btn btn-primary btn-sm"
        )
      end
    end

    it "returns no matching action for a user who cannot match deposits" do
      result = dr.workflow_progress(no_perms_user, bank_status: "waiting_for_matching", sales_imported: true, pos_imported: true)

      expect(current_key(result)).to eq(:bank_matching)
      expect(result[:action]).to be_nil
    end

    it "returns a warning-styled action for an open bank dispute even though bank_status is otherwise clean" do
      dep = deposit!(dr, amount: 50, depositor: depositor)
      dispute = BankDispute.create!(business: business, branch: branch, till_deposit: dep,
                                    opened_by: depositor, opened_at: Time.current,
                                    transaction_date: Date.current, amount: 50,
                                    bank_name: "NBE", terminal_id: "T-001")
      user = user_with("manage_bank_disputes", "view_daily_reconciliation")

      result = dr.workflow_progress(user, bank_status: "completed", open_disputes: [ dispute ], sales_imported: true, pos_imported: true)

      expect(step(result, :bank_statement)[:complete]).to be true
      expect(current_key(result)).to eq(:bank_matching)
      expect(result[:action]).to eq(
        label: "Match Bank Deposits", path: finance_daily_reconciliation_path(dr, anchor: "bank-deposits"),
        style: "btn btn-warning btn-sm"
      )
    end

    it "is complete once bank_status is completed and there are no open disputes", :aggregate_failures do
      result = dr.workflow_progress(no_perms_user, bank_status: "completed", sales_imported: true, pos_imported: true)

      expect(step(result, :bank_statement)[:complete]).to be true
      expect(step(result, :bank_matching)[:complete]).to be true
      expect(current_key(result)).to eq(:documentation)
    end
  end

  # ── Cash-only day (no bank deposit expected) ────────────────────────────
  describe "cash-only day (no_bank_transactions)" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor) }

    it "completes both bank steps once POS Import is done, without a matching requirement", :aggregate_failures do
      result = dr.workflow_progress(no_perms_user, bank_status: "no_bank_transactions", sales_imported: true, pos_imported: true)

      expect(step(result, :bank_statement)[:complete]).to be true
      expect(step(result, :bank_matching)[:complete]).to be true
      expect(current_key(result)).to eq(:documentation)
    end

    it "keeps its previous handling: neither bank step is complete before POS Import", :aggregate_failures do
      result = dr.workflow_progress(no_perms_user, bank_status: "no_bank_transactions", sales_imported: true, pos_imported: false)

      expect(step(result, :bank_statement)[:complete]).to be false
      expect(step(result, :bank_matching)[:complete]).to be false
      expect(current_key(result)).to eq(:pos_import)
    end
  end

  # ── Import completion from persisted statements (end to end) ────────────
  describe "bank statement import derived from persisted statements" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor) }
    let(:deposit_day) { Time.current.to_date }

    before do
      collect_cash!(dr, 100)
      deposit!(dr, amount: 100, depositor: depositor)
    end

    def import_step_complete?
      result = dr.reload.workflow_progress(no_perms_user, bank_status: dr.bank_reconciliation_status,
                                                          sales_imported: true, pos_imported: false)
      step(result, :bank_statement)[:complete]
    end

    it "is not complete before any statement is imported" do
      expect(import_step_complete?).to be false
    end

    it "is complete after a successful import covering the deposit for this branch, before POS Import" do
      create(:bank_statement, business: business, branch: branch,
                              statement_from: deposit_day - 1, statement_to: deposit_day + 1)

      expect(import_step_complete?).to be true
    end

    it "is complete for a business-wide statement (no branch) covering the deposit" do
      create(:bank_statement, business: business, branch: nil,
                              statement_from: deposit_day - 1, statement_to: deposit_day + 1)

      expect(import_step_complete?).to be true
    end

    it "is not complete for a statement of another branch" do
      create(:bank_statement, business: business, branch: create(:branch, business: business),
                              statement_from: deposit_day - 1, statement_to: deposit_day + 1)

      expect(import_step_complete?).to be false
    end

    it "is not complete for a statement that does not cover the deposit date" do
      create(:bank_statement, business: business, branch: branch,
                              statement_from: deposit_day - 10, statement_to: deposit_day - 2)

      expect(import_step_complete?).to be false
    end

    it "is not complete for a failed or still-pending import", :aggregate_failures do
      create(:bank_statement, :failed, business: business, branch: branch,
                                       statement_from: deposit_day - 1, statement_to: deposit_day + 1)
      expect(import_step_complete?).to be false

      create(:bank_statement, :pending, business: business, branch: branch,
                                        statement_from: deposit_day - 1, statement_to: deposit_day + 1)
      expect(import_step_complete?).to be false
    end

    it "is not complete for a deleted statement" do
      create(:bank_statement, business: business, branch: branch, deleted_at: Time.current,
                              statement_from: deposit_day - 1, statement_to: deposit_day + 1)

      expect(import_step_complete?).to be false
    end
  end

  # ── Step 8: Documentation (Verify) ──────────────────────────────────────
  describe "step 8 — documentation" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Document Reconciliation for a user with verify_daily_reconciliation once everything before it is done" do
      user = user_with("verify_daily_reconciliation", "view_daily_reconciliation")

      result = dr.workflow_progress(user, bank_status: "completed", sales_imported: true, pos_imported: true)

      expect(current_key(result)).to eq(:documentation)
      expect(result[:action]).to eq(
        label: "Document Reconciliation", path: finance_daily_reconciliation_path(dr, anchor: "approval"),
        style: "btn btn-primary btn-sm"
      )
    end

    it "never becomes current while sales/bank/pos import are still pending, even if already verified" do
      dr.update_columns(verified_at: 1.minute.ago, verified_by_id: depositor.id, state: "verified")

      result = dr.workflow_progress(no_perms_user, sales_imported: false)

      expect(current_key(result)).to eq(:sales_import)
    end
  end

  describe "fully completed" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "verified", depositor: depositor, verified: true) }

    it "returns nil for current step and nil action once every step is complete" do
      result = dr.workflow_progress(no_perms_user, bank_status: "completed", sales_imported: true, pos_imported: true)

      expect(current_key(result)).to be_nil
      expect(result[:action]).to be_nil
      expect(result[:steps].map { |s| s[:complete] }).to all(be true)
    end
  end
end
