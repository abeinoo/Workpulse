require "rails_helper"

# Browser behaviour of "Ignore selected" on Deposit Verification: eligible-only
# selection, header select/deselect (current page, indeterminate), clearing, the
# explicit "all matching" switch, and the reason-gated confirmation.
RSpec.describe "Deposit Verification bulk ignore", type: :system do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }
  let(:reviewer) do
    perms = %w[view_deposit_verification verify_deposits manual_match_deposits]
    role = business.permission_roles.create!(name: "Verifier", permissions: perms,
                                             permission_scopes: perms.index_with { "business_wide" })
    create(:user, business: business, preferred_locale: "en").tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:statement) do
    create(:bank_statement, :pending, business: business, branch: branch, statement_from: day - 3, statement_to: day + 3)
  end

  def line!(amount, status: "amount_mismatch")
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: amount,
                                     transaction_date: day, raw_data: {}, status: status)
  end

  def matched_line!(amount)
    dr  = DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                      opened_at: 1.hour.ago, business_date: day)
    dep = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: reviewer,
                              amount: amount, deposited_at: Time.current)
    line = line!(amount)
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: line)
    line
  end

  def row_box(line) = find(".dv-bulk-check-row[value='#{line.id}']")
  def master        = find(".dv-bulk-check-all")
  def bar           = find("[data-deposit-verification-bulk-ignore-target='actionBar']", visible: :all)
  def count_badge   = find("[data-deposit-verification-bulk-ignore-target='countBadge']", visible: :all)
  def bulk_t(key, **args) = I18n.t("finance.deposit_verifications.bulk_ignore.#{key}", **args)

  it "selects eligible rows, toggles the page, requires a reason and ignores the selection" do
    a, b, c = line!(10), line!(20), line!(30)
    linked  = matched_line!(250)
    sign_in reviewer
    visit finance_deposit_verifications_path(tab: "mismatches")

    expect(bar).not_to be_visible
    expect(row_box(linked)).to be_disabled

    row_box(a).check
    row_box(b).check
    expect(bar).to be_visible
    expect(count_badge.text).to eq("2")
    expect(master.evaluate_script("this.indeterminate")).to be(true)

    master.check # from indeterminate: selects every eligible row on the page
    expect(count_badge.text).to eq("3")
    expect(master.evaluate_script("this.indeterminate")).to be(false)

    master.uncheck
    expect(bar).not_to be_visible
    expect([ a, b, c ].map { |l| row_box(l).checked? }).to eq([ false, false, false ])

    master.check
    expect(count_badge.text).to eq("3")
    expect(row_box(linked)).not_to be_checked
    expect(page).not_to have_button(bulk_t(:select_all_matching, count: 3)) # nothing beyond this page

    click_button bulk_t(:button)
    expect(page).to have_text(bulk_t(:modal_body, count: 3))
    expect(page).to have_button(bulk_t(:confirm), disabled: true)
    fill_in "dv_bulk_ignore_reason", with: "Old bank fees before go-live"

    click_button bulk_t(:confirm)
    expect(page).to have_text(bulk_t(:done, count: 3))
    expect([ a, b, c ].map { |l| l.reload.status }).to all(eq("ignored"))
    expect(linked.reload.deposit_matches.count).to eq(1)
    expect(page).to have_css(".dv-bulk-check-row", count: 1) # only the linked line remains
  end

  it "clears the selection" do
    a = line!(10)
    line!(20)
    sign_in reviewer
    visit finance_deposit_verifications_path(tab: "mismatches")

    row_box(a).check
    click_button bulk_t(:clear)

    expect(bar).not_to be_visible
    expect(row_box(a)).not_to be_checked
  end

  it "selects all eligible lines across pages only when asked, and ignores them" do
    lines = Array.new(31) { |i| line!(100 + i) }
    sign_in reviewer
    visit finance_deposit_verifications_path(tab: "mismatches")

    master.check
    expect(count_badge.text).to eq("30")
    click_button bulk_t(:select_all_matching, count: 31)
    expect(count_badge.text).to eq("31")
    expect(page).to have_text(bulk_t(:all_matching_selected, count: 31))

    click_button bulk_t(:button)
    expect(page).to have_text(bulk_t(:modal_body, count: 31))
    fill_in "dv_bulk_ignore_reason", with: "Pre go-live noise"
    click_button bulk_t(:confirm)

    expect(page).to have_text(bulk_t(:done, count: 31))
    expect(lines.map { |l| l.reload.status }.uniq).to eq([ "ignored" ])
  end

  it "leaves all-matching mode as soon as one row is unticked" do
    lines = Array.new(31) { |i| line!(100 + i) }
    sign_in reviewer
    visit finance_deposit_verifications_path(tab: "mismatches")

    master.check
    click_button bulk_t(:select_all_matching, count: 31)
    first(".dv-bulk-check-row:not([disabled])").uncheck

    expect(count_badge.text).to eq("29")
    expect(page).not_to have_text(bulk_t(:all_matching_selected, count: 31))
    expect(lines.map { |l| l.reload.status }.uniq).to eq([ "amount_mismatch" ])
  end
end
