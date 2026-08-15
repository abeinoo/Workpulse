require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — refunds in Session Totals and Imported Sales Transactions",
               type: :request do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:cash_pm)   { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:visa_pm)   { PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer) do
    user_with("view_daily_reconciliation", "view_sales_transactions_verification", "view_session_totals")
  end

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: viewer.id) }

  def sales_txn!(amount:, type: "sale", payment_method_name: "Cash", reference_number: nil)
    sales_import = SalesImport.create!(business: business, imported_by: viewer, file_name: "export.csv", status: "imported")
    SalesTransaction.create!(
      business: business, sales_import: sales_import, daily_reconciliation: dr,
      transaction_date: Date.current, transaction_time: "10:00:00", cashier_name: "Ahmed", branch_name: branch.name,
      payment_method_name: payment_method_name, amount: amount, transaction_type: type,
      reference_number: reference_number
    )
  end

  def get_show
    sign_in viewer
    get finance_daily_reconciliation_path(dr)
    Nokogiri::HTML(response.body)
  end

  # ── 1. Session with sales and no refunds ────────────────────────────────
  it "shows Gross = Net and a zero Refunds column when there are no refunds" do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 2000, refund_amount: 0)

    doc = get_show
    row_text = doc.css("[data-controller='collapsible']")
      .find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip&.start_with?("Cash") }
      .at_css("[data-collapsible-target='trigger']").text

    expect(row_text).to include("2,000")
  end

  # ── 2. Session with cash sales + cash refund (WorkPulse/TillRefund side) ──
  it "shows Gross Sales, Refunds, and Net Sales for a payment method with a folded-in TillRefund" do
    dr.update!(state: "open", closed_at: nil)
    till_session.update!(current_holder: viewer)
    TillRefund.create!(daily_reconciliation: dr, payment_method: cash_pm, processed_by: viewer,
                       amount: 181, refunded_at: Time.current, notes: "Customer return")

    result = Finance::TillHandoverCreator.new(
      actor: viewer, daily_reconciliation_id: dr.id,
      params: { self_deposit: "1", depositor_type: "self",
                amounts: { cash_pm.id.to_s => { collected_amount: "2000", refund_amount: "0" } } }
    ).call
    expect(result.ok?).to be(true), result.error

    session_amount = dr.reload.session_amounts.find_by(payment_method: cash_pm)
    expect(session_amount.collected_amount).to eq(2000)
    expect(session_amount.refund_amount).to eq(181)
    expect(session_amount.net_amount).to eq(1819)

    doc = get_show
    trigger = doc.css("[data-controller='collapsible']")
      .find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip&.start_with?("Cash") }
      .at_css("[data-collapsible-target='trigger']")

    expect(trigger.text).to include("2,000")
    expect(trigger.text).to include("181")
    expect(trigger.text).to include("1,819")
  end

  # ── 3. Session with Visa sales + Visa refund (imported side) ────────────
  it "identifies an imported refund row as a refund, not a normal sale, with a negative signed amount" do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                              collected_amount: 280, refund_amount: 0)
    sale   = sales_txn!(amount: 500, type: "sale",   payment_method_name: "Visa", reference_number: "S-500")
    refund = sales_txn!(amount: 181, type: "refund", payment_method_name: "Visa", reference_number: "R-181")

    doc = get_show
    visa_block = doc.css("[data-controller='collapsible']")
      .find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip&.start_with?("Visa") }

    rows = visa_block.css("table").first.css("tbody tr")
    sale_row   = rows.find { |r| r.text.include?("S-500") }
    refund_row = rows.find { |r| r.text.include?("R-181") }

    expect(sale_row.text).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.type_sale"))
    expect(refund_row.text).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.type_refund"))
    expect(refund_row.text).to match(/-\s*181/)
    expect(sale.reload.signed_amount).to eq(500)
    expect(refund.reload.signed_amount).to eq(-181)
  end

  # ── 4. Multiple payment methods with refunds ─────────────────────────────
  it "keeps refunds correctly scoped per payment method — never lumped into Cash" do
    dr.update!(state: "open", closed_at: nil)
    till_session.update!(current_holder: viewer)
    TillRefund.create!(daily_reconciliation: dr, payment_method: visa_pm, processed_by: viewer,
                       amount: 50, refunded_at: Time.current)

    result = Finance::TillHandoverCreator.new(
      actor: viewer, daily_reconciliation_id: dr.id,
      params: { self_deposit: "1", depositor_type: "self",
                amounts: {
                  cash_pm.id.to_s => { collected_amount: "1000", refund_amount: "0" },
                  visa_pm.id.to_s => { collected_amount: "300",  refund_amount: "0" }
                } }
    ).call
    expect(result.ok?).to be(true), result.error

    cash_sa = dr.reload.session_amounts.find_by(payment_method: cash_pm)
    visa_sa = dr.reload.session_amounts.find_by(payment_method: visa_pm)
    expect(cash_sa.refund_amount).to eq(0)
    expect(visa_sa.refund_amount).to eq(50)
  end

  # ── 5. Reconciliation calculation: gross - refunds = net (imported side) ─
  it "computes Gross - Refunds = Net for the imported total, and compares NET against WorkPulse (not gross)" do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: visa_pm, payment_method_name: "Visa",
                              collected_amount: 319, refund_amount: 0)
    sales_txn!(amount: 500, type: "sale",   payment_method_name: "Visa", reference_number: "S-1")
    sales_txn!(amount: 181, type: "refund", payment_method_name: "Visa", reference_number: "R-1")

    doc = get_show
    # WorkPulse net (319) should now match imported net (500 - 181 = 319) —
    # i.e. no Difference badge for Visa (difference collapses to "—").
    visa_trigger = doc.css("[data-controller='collapsible']")
      .find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip&.start_with?("Visa") }
      .at_css("[data-collapsible-target='trigger']")

    expect(visa_trigger.text).to include("319")
    expect(response.body).to include(I18n.t("finance.sales_imports.verification.status_verified"))
  end

  # ── 6. Refund not double-counted across TillRefund / DailyReconciliation / session totals ──
  it "does not double count a TillRefund between DailyReconciliation#total_refunds and Session Totals" do
    dr.update!(state: "open", closed_at: nil)
    till_session.update!(current_holder: viewer)
    TillRefund.create!(daily_reconciliation: dr, payment_method: cash_pm, processed_by: viewer,
                       amount: 40, refunded_at: Time.current)
    TillRefund.create!(daily_reconciliation: dr, payment_method: cash_pm, processed_by: viewer,
                       amount: 15, refunded_at: Time.current)
    expect(dr.reload.total_refunds).to eq(55)

    result = Finance::TillHandoverCreator.new(
      actor: viewer, daily_reconciliation_id: dr.id,
      params: { self_deposit: "1", depositor_type: "self",
                amounts: { cash_pm.id.to_s => { collected_amount: "1000", refund_amount: "0" } } }
    ).call
    expect(result.ok?).to be(true), result.error

    expect(dr.reload.session_amounts.find_by(payment_method: cash_pm).refund_amount).to eq(55)

    # Re-syncing (e.g. a Day Close edit) must not double it.
    Finance::TillHandoverCreator.sync_session_amounts!(dr.reload, dr.day_close_handover)
    expect(dr.reload.session_amounts.find_by(payment_method: cash_pm).refund_amount).to eq(55)

    doc = get_show
    trigger = doc.css("[data-controller='collapsible']")
      .find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip&.start_with?("Cash") }
      .at_css("[data-collapsible-target='trigger']")
    expect(trigger.text).to include("55")
  end

  # ── 7. Traceability — the WorkPulse refund figure links back to the TillRefund records ──
  it "shows the individual TillRefund records behind a payment method's Refunds figure" do
    dr.update!(state: "open", closed_at: nil)
    till_session.update!(current_holder: viewer)
    refund = TillRefund.create!(daily_reconciliation: dr, payment_method: cash_pm, processed_by: viewer,
                                amount: 75, refunded_at: Time.current, notes: "Wrong item returned")

    doc = get_show
    cash_block = doc.css("[data-controller='collapsible']")
      .find { |d| d.at_css("[data-collapsible-target='trigger'] span")&.text&.strip&.start_with?("Cash") }

    expect(cash_block.text).to include(viewer.full_name)
    expect(cash_block.text).to include("Wrong item returned")
    expect(cash_block.text).to include("75")
    expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.electronic.workpulse_refunds_heading"))
  end
end
