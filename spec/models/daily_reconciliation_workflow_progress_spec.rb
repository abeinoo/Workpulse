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

  def make_dr(state:, business_date: Date.current, reviewed: false, verified: false, depositor: nil)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: state,
      opened_at: 1.hour.ago, closed_at: (Time.current if state != "open" && state != "waiting_for_opening"),
      business_date: business_date,
      reviewed_by: (depositor if reviewed), reviewed_at: (1.minute.ago if reviewed),
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

  it "returns all 8 steps in the fixed order" do
    dr = make_dr(state: "waiting_for_opening", business_date: Date.yesterday)

    expect(keys_of(dr.workflow_progress(no_perms_user))).to eq(
      %i[opening_float close_handover deposit deposit_review sales_import bank_statement pos_import documentation]
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

      expect(result[:steps].map { |s| s[:complete] }).to eq([ false, false, false, false, false, false, false, false ])
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
    it "never shows the Deposit action once the DR is already deposited and reviewed (badge = awaiting accounting approval), even with an open RDB shortfall" do
      depositor = create(:user, business: business)
      dr = make_dr(state: "deposited", depositor: depositor, reviewed: true)
      dep = deposit!(dr, amount: 60, depositor: depositor)
      RemainingDepositBalance.create!(
        daily_reconciliation: dr, till_deposit: dep, responsible_user: depositor, created_by: depositor,
        business: business, branch: branch, amount: 40, remaining_amount: 40, status: "open"
      )

      expect(dr.lifecycle_stage).to eq(:awaiting_accounting_approval)

      result = dr.workflow_progress(no_perms_user, sales_imported: false)

      expect(result[:steps].find { |s| s[:key] == :deposit }[:complete]).to be true
      expect(result[:steps].find { |s| s[:key] == :deposit_review }[:complete]).to be true
      expect(current_key(result)).to eq(:sales_import)
      expect(result[:action][:label]).to eq("Import Sales Transactions")
    end
  end

  # ── Step 4: Deposit Review ──────────────────────────────────────────────
  describe "step 4 — deposit_review" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: false) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Review Deposit for a user with review_daily_reconciliation" do
      user = user_with("review_daily_reconciliation", "view_daily_reconciliation")

      result = dr.workflow_progress(user)

      expect(current_key(result)).to eq(:deposit_review)
      expect(result[:action]).to eq(
        label: "Review Deposit", path: finance_daily_reconciliation_path(dr, anchor: "approval"), style: "btn btn-primary btn-sm"
      )
    end

    it "returns no action for a user without review_daily_reconciliation" do
      result = dr.workflow_progress(no_perms_user)

      expect(current_key(result)).to eq(:deposit_review)
      expect(result[:action]).to be_nil
    end
  end

  # ── Step 5: Sales Import ────────────────────────────────────────────────
  describe "step 5 — sales_import" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: true) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "is current and actionable (ungated) when sales_imported is false" do
      result = dr.workflow_progress(no_perms_user, sales_imported: false)

      expect(current_key(result)).to eq(:sales_import)
      expect(result[:action]).to eq(
        label: "Import Sales Transactions", path: new_finance_sales_import_path, style: "btn btn-primary btn-sm"
      )
    end

    it "is complete once sales_imported is true, advancing to the next step" do
      result = dr.workflow_progress(no_perms_user, sales_imported: true)

      expect(current_key(result)).not_to eq(:sales_import)
      expect(result[:steps].find { |s| s[:key] == :sales_import }[:complete]).to be true
    end
  end

  # ── Step 6: Bank Statement (import + matching + dispute resolution) ─────
  describe "step 6 — bank_statement" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: true) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Import Bank Statement when bank_status is waiting_for_bank_statement" do
      user = user_with("import_bank_statement", "view_deposit_verification")

      result = dr.workflow_progress(user, bank_status: "waiting_for_bank_statement", sales_imported: true)

      expect(current_key(result)).to eq(:bank_statement)
      expect(result[:action]).to eq(
        label: "Import Bank Statement", path: new_finance_bank_statement_path, style: "btn btn-primary btn-sm"
      )
    end

    %w[needs_review waiting_for_matching difference_found partially_matched].each do |status|
      it "returns the bank_statement action (pointing at matching) for bank_status=#{status}" do
        user = user_with("manual_match_deposits", "verify_deposits", "view_deposit_verification")

        result = dr.workflow_progress(user, bank_status: status, sales_imported: true)

        expect(current_key(result)).to eq(:bank_statement)
        expect(result[:action]).to eq(
          label: "Import Bank Statement", path: finance_daily_reconciliation_path(dr, anchor: "bank-deposits"),
          style: "btn btn-primary btn-sm"
        )
      end
    end

    it "returns a warning-styled action for an open bank dispute even though bank_status is otherwise clean" do
      dep = deposit!(dr, amount: 50, depositor: depositor)
      dispute = BankDispute.create!(business: business, branch: branch, till_deposit: dep,
                                    opened_by: depositor, opened_at: Time.current,
                                    transaction_date: Date.current, amount: 50,
                                    bank_name: "NBE", terminal_id: "T-001")
      user = user_with("manage_bank_disputes", "view_daily_reconciliation")

      result = dr.workflow_progress(user, bank_status: "completed", open_disputes: [ dispute ], sales_imported: true)

      expect(current_key(result)).to eq(:bank_statement)
      expect(result[:action]).to eq(
        label: "Import Bank Statement", path: finance_daily_reconciliation_path(dr, anchor: "bank-deposits"),
        style: "btn btn-warning btn-sm"
      )
    end

    it "is complete once bank_status is completed and there are no open disputes" do
      result = dr.workflow_progress(no_perms_user, bank_status: "completed", sales_imported: true)

      expect(current_key(result)).not_to eq(:bank_statement)
    end
  end

  # ── Step 7: POS Import ──────────────────────────────────────────────────
  describe "step 7 — pos_import" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: true) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Import POS Transactions for a user with manage_pos_import" do
      user = user_with("manage_pos_import", "view_pos_import")

      result = dr.workflow_progress(user, bank_status: "completed", sales_imported: true, pos_imported: false)

      expect(current_key(result)).to eq(:pos_import)
      expect(result[:action]).to eq(
        label: "Import POS Transactions", path: new_finance_pos_import_path, style: "btn btn-primary btn-sm"
      )
    end

    it "returns no action for a user without manage_pos_import" do
      result = dr.workflow_progress(no_perms_user, bank_status: "completed", sales_imported: true, pos_imported: false)

      expect(current_key(result)).to eq(:pos_import)
      expect(result[:action]).to be_nil
    end

    it "is complete once pos_imported is true" do
      result = dr.workflow_progress(no_perms_user, bank_status: "completed", sales_imported: true, pos_imported: true)

      expect(current_key(result)).not_to eq(:pos_import)
    end
  end

  # ── Step 8: Documentation (Verify) ──────────────────────────────────────
  describe "step 8 — documentation" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: true) }

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
    let(:dr) { make_dr(state: "verified", depositor: depositor, reviewed: true, verified: true) }

    it "returns nil for current step and nil action once every step is complete" do
      result = dr.workflow_progress(no_perms_user, bank_status: "completed", sales_imported: true, pos_imported: true)

      expect(current_key(result)).to be_nil
      expect(result[:action]).to be_nil
      expect(result[:steps].map { |s| s[:complete] }).to all(be true)
    end
  end
end
