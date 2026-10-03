require "rails_helper"

# A branch may appear only once in a shared expense's distribution, for every
# distribution method. The duplicate is caught by Expense validation (a 422
# with an Arabic message) instead of reaching the unique index as a 500.
RSpec.describe "Finance::Expenses duplicate distribution branch", type: :request do
  let(:business) { create(:business, currency: "EGP") }
  let(:owner)    { create(:user, :owner, business: business, preferred_locale: "ar") }
  let(:category) { create(:expense_category, business: business) }
  let(:b1)       { create(:branch, business: business) }
  let(:b2)       { create(:branch, business: business) }

  let(:duplicate_message) { "لا يمكن إضافة نفس الفرع أكثر من مرة في توزيع المصروف." }

  before { sign_in owner }

  def shared_params(method:, rows:, amount: 100)
    {
      expense: {
        expense_category_id: category.id, amount: amount.to_s, expense_date: "2026-08-09",
        branch_id: "shared", payment_type: "installment", distribution_method: method,
        expense_allocations_attributes: rows.each_with_index.to_h { |row, i| [ i.to_s, row ] }
      }
    }
  end

  def expect_duplicate_rejected
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include(duplicate_message)
    expect(controller.instance_variable_get(:@expense).errors.full_messages).to eq([ duplicate_message ])
  end

  describe "creating" do
    {
      "percentage" => [ { allocation_percentage: "50" }, { allocation_percentage: "50" } ],
      "equal"      => [ {}, {} ],
      "manual"     => [ { allocated_amount: "50" }, { allocated_amount: "50" } ]
    }.each do |method, row_attrs|
      it "rejects the same branch twice with a validation error (#{method})" do
        rows = row_attrs.map { |attrs| attrs.merge(branch_id: b1.id) }

        expect {
          post finance_expenses_path, params: shared_params(method: method, rows: rows)
        }.not_to raise_error

        expect_duplicate_rejected
        expect(Expense.count).to eq(0)
        expect(ExpenseAllocation.count).to eq(0)
      end
    end

    it "reports only the duplicate error, not a misleading total error" do
      rows = [ { branch_id: b1.id, allocated_amount: "50" }, { branch_id: b1.id, allocated_amount: "10" } ]
      post finance_expenses_path, params: shared_params(method: "manual", rows: rows)

      expect_duplicate_rejected
      expect(response.body).not_to include("40.00 ج.م")
    end

    it "still accepts distinct branches (percentage)" do
      rows = [ { branch_id: b1.id, allocation_percentage: "60" }, { branch_id: b2.id, allocation_percentage: "40" } ]
      expect {
        post finance_expenses_path, params: shared_params(method: "percentage", rows: rows, amount: 200)
      }.to change(Expense, :count).by(1)
      expect(Expense.last.expense_allocations.order(:id).map(&:allocated_amount)).to eq([ 120, 80 ])
    end

    it "still accepts distinct branches (equal)" do
      expect {
        post finance_expenses_path, params: shared_params(method: "equal", rows: [ { branch_id: b1.id }, { branch_id: b2.id } ])
      }.to change(Expense, :count).by(1)
      expect(Expense.last.expense_allocations.map(&:allocated_amount)).to eq([ 50, 50 ])
    end

    it "still accepts distinct branches (amount)" do
      rows = [ { branch_id: b1.id, allocated_amount: "80" }, { branch_id: b2.id, allocated_amount: "20" } ]
      expect {
        post finance_expenses_path, params: shared_params(method: "manual", rows: rows)
      }.to change(Expense, :count).by(1)
    end
  end

  describe "editing" do
    let!(:expense) do
      post finance_expenses_path, params: shared_params(
        method: "percentage",
        rows: [ { branch_id: b1.id, allocation_percentage: "60" }, { branch_id: b2.id, allocation_percentage: "40" } ]
      )
      Expense.last
    end
    let(:a1) { expense.expense_allocations.find_by!(branch_id: b1.id) }
    let(:a2) { expense.expense_allocations.find_by!(branch_id: b2.id) }

    def patch_rows(rows)
      patch finance_expense_path(expense), params: {
        expense: { expense_allocations_attributes: rows.each_with_index.to_h { |row, i| [ i.to_s, row ] } }
      }
    end

    it "rejects a new row for a branch an existing row already holds" do
      expect {
        patch_rows([
          { id: a1.id, branch_id: b1.id, allocation_percentage: "30" },
          { id: a2.id, branch_id: b2.id, allocation_percentage: "40" },
          { branch_id: b1.id, allocation_percentage: "30" }
        ])
      }.not_to raise_error

      expect_duplicate_rejected
      expect(expense.expense_allocations.reload.map(&:branch_id)).to contain_exactly(b1.id, b2.id)
    end

    it "rejects changing an existing row to a branch another row holds" do
      patch_rows([
        { id: a1.id, branch_id: b1.id, allocation_percentage: "60" },
        { id: a2.id, branch_id: b1.id, allocation_percentage: "40" }
      ])

      expect_duplicate_rejected
      expect(a2.reload.branch_id).to eq(b2.id)
    end

    it "returns a validation error, not a 500, when two rows swap branches" do
      expect {
        patch_rows([
          { id: a1.id, branch_id: b2.id, allocation_percentage: "60" },
          { id: a2.id, branch_id: b1.id, allocation_percentage: "40" }
        ])
      }.not_to raise_error

      expect_duplicate_rejected
      expect(a1.reload.branch_id).to eq(b1.id)
      expect(a2.reload.branch_id).to eq(b2.id)
    end

    it "allows replacing a removed row with a new row for the same branch" do
      patch_rows([
        { id: a1.id, branch_id: b1.id, _destroy: "1" },
        { id: a2.id, branch_id: b2.id, allocation_percentage: "40" },
        { branch_id: b1.id, allocation_percentage: "60" }
      ])

      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.expense_allocations.reload.map(&:branch_id)).to contain_exactly(b1.id, b2.id)
      expect(ExpenseAllocation.exists?(a1.id)).to be false
    end
  end

  it "is a model validation, independent of the controller" do
    expense = build(:expense, business: business, branch: nil, expense_category: category,
                              amount: 100, distribution_method: "equal")
    expense.expense_allocations.build(branch: b1, allocation_percentage: 50, allocated_amount: 50)
    expense.expense_allocations.build(branch: b1, allocation_percentage: 50, allocated_amount: 50)

    I18n.with_locale(:ar) do
      expect(expense).not_to be_valid
      expect(expense.errors[:base]).to include(duplicate_message)
    end
  end
end
