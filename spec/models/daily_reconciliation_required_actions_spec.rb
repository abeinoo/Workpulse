require "rails_helper"

RSpec.describe DailyReconciliation, "#required_actions" do
  include Rails.application.routes.url_helpers

  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current,
      reviewed_by: actor, reviewed_at: 1.minute.ago
    )
  end

  it "is empty when the POS file is imported and bank matching isn't pending" do
    expect(dr.required_actions(bank_status: "completed", pos_imported: true)).to eq([])
  end

  it "flags Import POS File when the POS file hasn't been imported yet" do
    actions = dr.required_actions(bank_status: "completed", pos_imported: false)

    expect(actions.size).to eq(1)
    expect(actions.first).to include(
      label: "Import POS File",
      path: new_finance_pos_import_path
    )
  end

  %w[needs_review waiting_for_matching difference_found partially_matched].each do |status|
    it "flags Match Bank Transactions when bank_status is #{status}" do
      actions = dr.required_actions(bank_status: status, pos_imported: true)

      expect(actions.size).to eq(1)
      expect(actions.first).to include(
        label: "Match Bank Transactions",
        path: finance_daily_reconciliation_path(dr, anchor: "bank-deposits")
      )
    end
  end

  it "does not flag matching for bank statuses where matching isn't the blocker" do
    %w[no_bank_transactions waiting_for_deposit waiting_for_bank_statement completed].each do |status|
      expect(dr.required_actions(bank_status: status, pos_imported: true)).to eq([])
    end
  end

  it "shows BOTH required actions at once when both conditions hold — independent, not exclusive" do
    actions = dr.required_actions(bank_status: "needs_review", pos_imported: false)

    labels = actions.map { |a| a[:label] }
    expect(labels).to contain_exactly("Import POS File", "Match Bank Transactions")
  end

  it "is completely independent of next_action_for — both a primary action and a required action can apply simultaneously" do
    # DR is "Waiting for Branch Review" (deposited, not reviewed) — the primary
    # next_action_for candidate — while the POS file is separately missing.
    review_dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "deposited",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: review_dr, depositor_id: actor.id)

    reviewer = create(:user, business: business)
    role = business.permission_roles.create!(
      name: "Reviewer", permissions: %w[review_daily_reconciliation view_daily_reconciliation],
      permission_scopes: { "review_daily_reconciliation" => "business_wide", "view_daily_reconciliation" => "business_wide" }
    )
    reviewer.update_column(:permission_role_id, role.id)

    primary = review_dr.next_action_for(reviewer)
    secondary = review_dr.required_actions(bank_status: "waiting_for_deposit", pos_imported: false)

    expect(primary[:label]).to eq("Review Reconciliation")
    expect(secondary.map { |a| a[:label] }).to eq([ "Import POS File" ])
  end
end
