require "rails_helper"

# The Daily Reconciliations index card's workflow checklist: "Import Bank
# Statement" turns green once a statement is imported for the day, without
# waiting for POS Import or for matching; "Match Bank Deposits" carries the
# matching requirement separately.
RSpec.describe "Finance::DailyReconciliations index — bank workflow steps", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business, preferred_locale: "en") }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.to_date }

  let!(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current).tap do |d|
      TillSession.create!(daily_reconciliation: d, depositor_id: owner.id)
      TillSessionAmount.create!(daily_reconciliation: d, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 100, refund_amount: 0)
      TillDeposit.create!(daily_reconciliation: d, payment_method: cash_pm, deposited_by: owner,
                          amount: 100, deposited_at: Time.current)
    end
  end

  def success_color = "var(--success,#16a34a)"

  def step_label(key) = I18n.t("finance.daily_reconciliations.index.workspace.workflow.steps.#{key}")

  # The checklist <span> for a step, matched on its exact label.
  def step_span(key)
    get finance_daily_reconciliations_path
    expect(response).to have_http_status(:ok)
    label = step_label(key)
    Nokogiri::HTML(response.body).css(".dr-card span").find { |s| s.text.squish.end_with?(" #{label}") }
  end

  def import_statement!(**attrs)
    create(:bank_statement, business: business, branch: branch,
                            statement_from: day - 1, statement_to: day + 1, **attrs)
  end

  before { sign_in owner }

  it "is not green before any bank statement is imported", :aggregate_failures do
    span = step_span(:bank_statement)

    expect(span).to be_present
    expect(span.text).to include("○")
    expect(span["style"]).not_to include(success_color)
  end

  it "turns green after a successful import, while POS Import is still pending", :aggregate_failures do
    import_statement!

    span = step_span(:bank_statement)
    expect(span.text).to include("✓")
    expect(span["style"]).to include(success_color)

    pos = step_span(:pos_import)
    expect(pos.text).to include("○")
    expect(pos["style"]).not_to include(success_color)

    matching = step_span(:bank_matching)
    expect(matching.text).to include("○")
    expect(matching["style"]).not_to include(success_color)
  end

  it "does not turn green for a failed import" do
    import_statement!(status: "failed")

    expect(step_span(:bank_statement)["style"]).not_to include(success_color)
  end

  it "does not turn green for another branch's statement" do
    import_statement!(branch: create(:branch, business: business))

    expect(step_span(:bank_statement)["style"]).not_to include(success_color)
  end

  it "renders the same states in Arabic", :aggregate_failures do
    owner.update!(preferred_locale: "ar")
    import_statement!

    I18n.with_locale(:ar) do
      expect(step_span(:bank_statement)["style"]).to include(success_color)
      expect(step_span(:bank_matching)["style"]).not_to include(success_color)
    end
  end
end
