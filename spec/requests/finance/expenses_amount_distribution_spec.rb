require "rails_helper"

# "By amount" (بالقيمة) branch distribution for shared expenses — stored as
# distribution_method "manual". The entered branch amounts must equal the
# expense amount exactly; enforced server-side in Expense regardless of what
# the form's live summary allowed.
RSpec.describe "Finance::Expenses amount distribution", type: :request do
  let(:business) { create(:business, currency: "EGP") }
  let(:owner)    { create(:user, :owner, business: business, preferred_locale: "ar") }
  let(:category) { create(:expense_category, business: business) }
  let(:b1)       { create(:branch, business: business) }
  let(:b2)       { create(:branch, business: business) }
  let(:b3)       { create(:branch, business: business) }

  before { sign_in owner }

  def shared_params(amount:, method:, rows:)
    {
      expense: {
        expense_category_id: category.id, amount: amount.to_s, expense_date: "2026-08-09",
        branch_id: "shared", payment_type: "installment", distribution_method: method,
        expense_allocations_attributes: rows.each_with_index.to_h { |row, i| [ i.to_s, row ] }
      }
    }
  end

  def amount_rows(map) = map.map { |branch, amt| { branch_id: branch.id, allocated_amount: amt.to_s } }
  def pct_rows(map)    = map.map { |branch, pct| { branch_id: branch.id, allocation_percentage: pct.to_s } }

  def post_amounts(amount, map)
    post finance_expenses_path, params: shared_params(amount: amount, method: "manual", rows: amount_rows(map))
  end

  def allocations_of(expense)
    expense.expense_allocations.order(:id).map { |a| [ a.branch_id, a.allocated_amount ] }
  end

  describe "creating a shared expense by amount" do
    it "allocates the full amount to a single branch" do
      expect { post_amounts(100, b1 => 100) }.to change(Expense, :count).by(1)

      expense = Expense.last
      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.distribution_method).to eq("manual")
      expect(expense).to be_is_shared
      expect(allocations_of(expense)).to eq([ [ b1.id, 100 ] ])
      expect(expense.expense_allocations.first.allocation_percentage).to eq(100)
    end

    it "splits across multiple branches by exact amounts (80 / 20)" do
      expect { post_amounts(100, b1 => 80, b2 => 20) }.to change(Expense, :count).by(1)

      expense = Expense.last
      expect(allocations_of(expense)).to eq([ [ b1.id, 80 ], [ b2.id, 20 ] ])
      expect(expense.expense_allocations.sum(:allocated_amount)).to eq(expense.amount)
      expect(expense.expense_allocations.order(:id).map(&:allocation_percentage)).to eq([ 80, 20 ])
    end

    it "accepts decimal amounts that add up exactly" do
      expect { post_amounts("100.00", b1 => "33.33", b2 => "33.33", b3 => "33.34") }.to change(Expense, :count).by(1)

      expense = Expense.last
      expect(expense.expense_allocations.map(&:allocated_amount)).to contain_exactly(
        BigDecimal("33.33"), BigDecimal("33.33"), BigDecimal("33.34")
      )
      expect(expense.expense_allocations.sum(:allocated_amount)).to eq(BigDecimal("100.00"))
    end

    it "matches exactly where float addition would drift (0.1 + 0.2 = 0.3)" do
      expect { post_amounts("0.3", b1 => "0.1", b2 => "0.2") }.to change(Expense, :count).by(1)
      expect(Expense.last.expense_allocations.sum(:allocated_amount)).to eq(BigDecimal("0.3"))
    end

    it "keeps a tiny positive share valid (derived percentage never rounds to 0%)" do
      expect { post_amounts("20000", b1 => "19999.50", b2 => "0.50") }.to change(Expense, :count).by(1)
      expect(Expense.last.expense_allocations.order(:id).last.allocation_percentage).to eq(BigDecimal("0.01"))
    end

    it "rejects a distribution below the expense amount and states the remainder" do
      expect { post_amounts(100, b1 => 80) }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(
        "يجب أن يساوي إجمالي توزيع الفروع مبلغ المصروف بالكامل. المتبقي للتوزيع: 20.00 ج.م."
      )
    end

    it "rejects a distribution above the expense amount and states the excess" do
      expect { post_amounts(100, b1 => 80, b2 => 30) }.not_to change(Expense, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("إجمالي توزيع الفروع يتجاوز مبلغ المصروف بمقدار 10.00 ج.م.")
    end

    it "rejects a decimal shortfall of one cent" do
      expect { post_amounts("100.00", b1 => "33.33", b2 => "33.33", b3 => "33.33") }.not_to change(Expense, :count)
      expect(response.body).to include("المتبقي للتوزيع: 0.01 ج.م.")
    end

    it "rejects amounts with more than 2 decimals instead of letting the DB round them" do
      expect { post_amounts("100", b1 => "50.005", b2 => "49.995") }.not_to change(Expense, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects a zero-amount branch row" do
      expect { post_amounts(100, b1 => 100, b2 => 0) }.not_to change(Expense, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "server-side validation cannot be bypassed" do
    it "ignores tampered percentages that total 100 when amounts do not match" do
      rows = [
        { branch_id: b1.id, allocated_amount: "10", allocation_percentage: "50" },
        { branch_id: b2.id, allocated_amount: "10", allocation_percentage: "50" }
      ]
      expect {
        post finance_expenses_path, params: shared_params(amount: 100, method: "manual", rows: rows)
      }.not_to change(Expense, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects a mismatched amount distribution saved outside the controller" do
      expense = build(:expense, business: business, branch: nil, expense_category: category,
                                amount: 100, distribution_method: "manual")
      expense.expense_allocations.build(branch: b1, allocated_amount: 60, allocation_percentage: 100)

      I18n.with_locale(:ar) do
        expect(expense).not_to be_valid
        expect(expense.errors[:base]).to include(
          "يجب أن يساوي إجمالي توزيع الفروع مبلغ المصروف بالكامل. المتبقي للتوزيع: 40.00 ج.م."
        )
      end
    end
  end

  describe "editing the expense after distributing" do
    let!(:expense) do
      post_amounts(100, b1 => 80, b2 => 20)
      Expense.last
    end

    it "rejects a new expense amount that no longer matches the distribution" do
      patch finance_expense_path(expense), params: { expense: { amount: "150" } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("المتبقي للتوزيع: 50.00 ج.م.")
      expect(expense.reload.amount).to eq(100)
    end

    it "saves once the distribution is re-balanced to the new amount" do
      a1, a2 = expense.expense_allocations.order(:id).to_a
      patch finance_expense_path(expense), params: {
        expense: {
          amount: "150",
          expense_allocations_attributes: {
            "0" => { id: a1.id, branch_id: b1.id, allocated_amount: "100" },
            "1" => { id: a2.id, branch_id: b2.id, allocated_amount: "50" }
          }
        }
      }

      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.reload.amount).to eq(150)
      expect(allocations_of(expense)).to eq([ [ b1.id, 100 ], [ b2.id, 50 ] ])
    end
  end

  describe "existing methods are unchanged" do
    it "percentage: derives amounts from percentages; amounts submitted are ignored" do
      rows = [
        { branch_id: b1.id, allocation_percentage: "60", allocated_amount: "999" },
        { branch_id: b2.id, allocation_percentage: "40" }
      ]
      expect {
        post finance_expenses_path, params: shared_params(amount: 200, method: "percentage", rows: rows)
      }.to change(Expense, :count).by(1)
      expect(allocations_of(Expense.last)).to eq([ [ b1.id, 120 ], [ b2.id, 80 ] ])
    end

    it "percentage: still requires a 100% total" do
      expect {
        post finance_expenses_path, params: shared_params(amount: 200, method: "percentage", rows: pct_rows(b1 => 60, b2 => 30))
      }.not_to change(Expense, :count)
      expect(response.body).to include(I18n.t("activerecord.errors.messages.allocation_not_100", locale: :ar))
    end

    it "equal: splits evenly with the residual on the last branch" do
      rows = [ { branch_id: b1.id }, { branch_id: b2.id }, { branch_id: b3.id } ]
      expect {
        post finance_expenses_path, params: shared_params(amount: 100, method: "equal", rows: rows)
      }.to change(Expense, :count).by(1)

      expense = Expense.last
      expect(expense.expense_allocations.order(:id).map(&:allocated_amount)).to eq([ 33.33, 33.33, 33.34 ])
      expect(expense.expense_allocations.order(:id).map(&:allocation_percentage)).to eq([ 33.33, 33.33, 33.34 ])
    end
  end
end
