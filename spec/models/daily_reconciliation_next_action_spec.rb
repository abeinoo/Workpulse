require "rails_helper"

RSpec.describe DailyReconciliation, "#next_action_for" do
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

  # ── 1. Waiting for Opening Balance ──────────────────────────────────────
  describe "waiting for opening balance" do
    let(:dr) { make_dr(state: "waiting_for_opening", business_date: Date.yesterday) }

    it "returns Enter Opening Balance when the user has cashier permission" do
      user = user_with("create_till_session", "close_till_session")

      action = dr.next_action_for(user)

      expect(action).to eq(
        label: "Enter Opening Balance", icon: "wallet",
        path: finance_daily_reconciliation_path(dr),
        permission: "create_opening_balance", style: "btn btn-primary btn-sm", method: :get
      )
    end

    it "returns nil when the user lacks any cashier permission" do
      expect(dr.next_action_for(no_perms_user)).to be_nil
    end

    it "returns nil when the float isn't receivable yet (business day hasn't reached it)" do
      future_dr = make_dr(state: "waiting_for_opening", business_date: Date.tomorrow + 5)
      user = user_with("create_till_session", "close_till_session")

      expect(future_dr.next_action_for(user)).to be_nil
    end
  end

  # ── 2. Deposit Required ─────────────────────────────────────────────────
  describe "deposit required (closed, no deposit yet)" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "closed", depositor: depositor) }

    it "returns Record Deposit when the assigned depositor has permission" do
      depositor.update_column(
        :permission_role_id,
        business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: %w[create_till_deposit close_till_session],
                                          permission_scopes: { "create_till_deposit" => "business_wide", "close_till_session" => "business_wide" }).id
      )

      action = dr.next_action_for(depositor)

      expect(action).to eq(
        label: "Record Deposit", icon: "plus-circle",
        path: new_till_deposit_path(daily_reconciliation_id: dr.id),
        permission: "record_deposit", style: "btn btn-primary btn-sm", method: :get
      )
    end

    it "returns nil for a user without create_till_deposit" do
      expect(dr.next_action_for(no_perms_user)).to be_nil
    end

    it "returns nil for someone with the permission who isn't the assigned depositor" do
      other = user_with("create_till_deposit", "close_till_session")
      expect(dr.next_action_for(other)).to be_nil
    end
  end

  # ── 3. Outstanding Balance Exists ───────────────────────────────────────
  describe "outstanding balance exists (deposited with an open shortfall)" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: false) }

    before do
      dep = deposit!(dr, amount: 60, depositor: depositor)
      RemainingDepositBalance.create!(
        daily_reconciliation: dr, till_deposit: dep, responsible_user: depositor, created_by: depositor,
        business: business, branch: branch, amount: 40, remaining_amount: 40, status: "open"
      )
    end

    it "returns Record Additional Deposit when the assigned depositor has permission" do
      depositor.update_column(
        :permission_role_id,
        business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: %w[create_till_deposit close_till_session],
                                          permission_scopes: { "create_till_deposit" => "business_wide", "close_till_session" => "business_wide" }).id
      )

      action = dr.next_action_for(depositor)

      expect(action[:label]).to eq("Record Additional Deposit")
      expect(action[:path]).to eq(new_till_deposit_path(daily_reconciliation_id: dr.id))
      expect(action[:permission]).to eq("record_deposit")
    end

    it "takes priority over the later Waiting for Branch Review stage even though the DR is already deposited" do
      depositor.update_column(
        :permission_role_id,
        business.permission_roles.create!(
          name: "R-#{SecureRandom.hex(3)}",
          permissions: %w[create_till_deposit close_till_session review_daily_reconciliation view_daily_reconciliation],
          permission_scopes: {
            "create_till_deposit" => "business_wide", "close_till_session" => "business_wide",
            "review_daily_reconciliation" => "business_wide", "view_daily_reconciliation" => "business_wide"
          }
        ).id
      )

      expect(dr.next_action_for(depositor)[:label]).to eq("Record Additional Deposit")
    end

    it "returns nil for a user without permission" do
      expect(dr.next_action_for(no_perms_user)).to be_nil
    end
  end

  # ── 4. Waiting for Bank Statement ───────────────────────────────────────
  describe "waiting for bank statement" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: true) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Import Bank Statement for a user with import_bank_statement" do
      user = user_with("import_bank_statement", "view_deposit_verification")

      action = dr.next_action_for(user, bank_status: "waiting_for_bank_statement")

      expect(action).to eq(
        label: "Import Bank Statement", icon: "upload",
        path: new_finance_bank_statement_path,
        permission: "import_bank_statement", style: "btn btn-primary btn-sm", method: :get
      )
    end

    it "returns nil for a user without import_bank_statement" do
      expect(dr.next_action_for(no_perms_user, bank_status: "waiting_for_bank_statement")).to be_nil
    end
  end

  # ── 5. Waiting for Matching ──────────────────────────────────────────────
  describe "waiting for matching" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: true) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    %w[needs_review waiting_for_matching difference_found partially_matched].each do |status|
      it "returns Match Transactions for bank_status=#{status} when the user can manually match" do
        user = user_with("manual_match_deposits", "verify_deposits", "view_deposit_verification")

        action = dr.next_action_for(user, bank_status: status)

        expect(action[:label]).to eq("Match Transactions")
        expect(action[:path]).to eq(finance_daily_reconciliation_path(dr, anchor: "bank-deposits"))
        expect(action[:permission]).to eq("match_bank_transactions")
      end
    end

    it "returns nil for a user without manual_match_deposits" do
      expect(dr.next_action_for(no_perms_user, bank_status: "needs_review")).to be_nil
    end
  end

  # ── 6. Waiting for Branch Review ────────────────────────────────────────
  describe "waiting for branch review (deposited, not reviewed)" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: false) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Review Reconciliation for a user with review_daily_reconciliation" do
      user = user_with("review_daily_reconciliation", "view_daily_reconciliation")

      action = dr.next_action_for(user)

      expect(action).to eq(
        label: "Review Reconciliation", icon: "check-square",
        path: finance_daily_reconciliation_path(dr, anchor: "approval"),
        permission: "review_daily_reconciliation", style: "btn btn-primary btn-sm", method: :get
      )
    end

    it "returns nil for a user without review_daily_reconciliation" do
      expect(dr.next_action_for(no_perms_user)).to be_nil
    end
  end

  # ── 7. Waiting for Verification ─────────────────────────────────────────
  describe "waiting for verification (deposited and reviewed, not verified)" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "deposited", depositor: depositor, reviewed: true) }

    before { deposit!(dr, amount: 100, depositor: depositor) }

    it "returns Verify Reconciliation for a user with verify_daily_reconciliation" do
      user = user_with("verify_daily_reconciliation", "view_daily_reconciliation")

      action = dr.next_action_for(user)

      expect(action).to eq(
        label: "Verify Reconciliation", icon: "shield-check",
        path: finance_daily_reconciliation_path(dr, anchor: "approval"),
        permission: "verify_daily_reconciliation", style: "btn btn-primary btn-sm", method: :get
      )
    end

    it "returns nil for a user without verify_daily_reconciliation" do
      expect(dr.next_action_for(no_perms_user)).to be_nil
    end
  end

  # ── 8. Open Bank Dispute ────────────────────────────────────────────────
  describe "open bank dispute" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "verified", depositor: depositor, reviewed: true, verified: true) }
    let(:deposit) { deposit!(dr, amount: 100, depositor: depositor) }
    let(:dispute) do
      BankDispute.create!(business: business, branch: branch, till_deposit: deposit,
                          opened_by: depositor, opened_at: Time.current,
                          transaction_date: Date.current, amount: 100,
                          bank_name: "NBE", terminal_id: "T-001")
    end

    it "returns Review Bank Dispute for a user with manage_bank_disputes, even on an already-verified DR" do
      user = user_with("manage_bank_disputes", "view_daily_reconciliation")

      action = dr.next_action_for(user, open_disputes: [ dispute ])

      expect(action).to eq(
        label: "Review Bank Dispute", icon: "alert-triangle",
        path: finance_daily_reconciliation_path(dr, anchor: "bank-deposits"),
        permission: "resolve_bank_dispute", style: "btn btn-warning btn-sm", method: :get
      )
    end

    it "returns nil for a user without manage_bank_disputes" do
      expect(dr.next_action_for(no_perms_user, open_disputes: [ dispute ])).to be_nil
    end
  end

  # ── 9. Verified ──────────────────────────────────────────────────────────
  describe "verified" do
    let(:depositor) { create(:user, business: business) }
    let(:dr) { make_dr(state: "verified", depositor: depositor, reviewed: true, verified: true) }

    it "returns nil regardless of the viewer's permissions" do
      owner = create(:user, :owner, business: business)

      expect(dr.next_action_for(owner)).to be_nil
      expect(dr.next_action_for(no_perms_user)).to be_nil
    end
  end
end
