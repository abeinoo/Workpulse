require "rails_helper"

RSpec.describe Finance::PosImports::ExpenseGenerator do
  let(:business) { create(:business) }
  let(:actor)    { create(:user, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:pos_import) { create(:pos_import, business: business, imported_by: actor) }

  def transaction(branch:, fees:, administrative_fees:)
    create(:pos_transaction, business: business, pos_import: pos_import, branch: branch,
                            fees: fees, administrative_fees: administrative_fees)
  end

  it "creates one aggregate expense per branch with nonzero fees" do
    transaction(branch: branch_a, fees: 5, administrative_fees: 2)
    transaction(branch: branch_a, fees: 3, administrative_fees: 0)
    transaction(branch: branch_b, fees: 10, administrative_fees: 1)

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).to be_ok
    expect(result.expenses.size).to eq(2)
    expect(result.expenses.map(&:branch_id)).to contain_exactly(branch_a.id, branch_b.id)
    expect(result.expenses.find { |e| e.branch_id == branch_a.id }.amount).to eq(10)
    expect(result.expenses.find { |e| e.branch_id == branch_b.id }.amount).to eq(11)
  end

  it "creates no expense for a branch whose total fees are zero" do
    transaction(branch: branch_a, fees: 0, administrative_fees: 0)

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).to be_ok
    expect(result.expenses).to be_empty
  end

  it "creates the Payment Gateway Fees category on first use" do
    transaction(branch: branch_a, fees: 5, administrative_fees: 0)

    expect {
      described_class.call(pos_import.id, actor: actor)
    }.to change { business.expense_categories.where(name: "Payment Gateway Fees").count }.by(1)
  end

  it "reuses the existing category on subsequent imports" do
    business.expense_categories.create!(name: "Payment Gateway Fees", active: true)
    transaction(branch: branch_a, fees: 5, administrative_fees: 0)

    expect {
      described_class.call(pos_import.id, actor: actor)
    }.not_to change { business.expense_categories.count }
  end

  it "generates the expense with status pending_approval and a unique reference_number" do
    transaction(branch: branch_a, fees: 5, administrative_fees: 0)

    result = described_class.call(pos_import.id, actor: actor)

    expense = result.expenses.first
    expect(expense.status).to eq("pending_approval")
    expect(expense.reference_number).to be_present
    expect(expense.source_pos_import_id).to eq(pos_import.id)
  end

  it "links the generated expense back to the pos_import" do
    transaction(branch: branch_a, fees: 5, administrative_fees: 0)

    result = described_class.call(pos_import.id, actor: actor)

    expect(pos_import.generated_expenses.reload).to include(result.expenses.first)
  end
end
