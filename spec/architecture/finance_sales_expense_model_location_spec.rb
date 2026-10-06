require "rails_helper"

# Milestone 2 — Finance & Sales Expenses (M7): the Expenses models live
# physically in Finance & Sales (app/models/finance_sales/, the collapsed
# directory from config/initializers/finance_sales_autoload.rb) but keep their
# top-level constants and tables. Guards against an accidental un-collapse,
# namespace or table change.
RSpec.describe "Architecture: Finance & Sales expense model location" do
  models = {
    Expense                    => "expenses",
    ExpenseAllocation          => "expense_allocations",
    ExpenseCategory            => "expense_categories",
    ExpenseType                => "expense_types",
    ExpenseTag                 => "expense_tags",
    ExpenseTagging             => "expense_taggings",
    RecurringExpense           => "recurring_expenses",
    RecurringExpenseAllocation => "recurring_expense_allocations"
  }

  models.each do |model, table|
    describe model.name do
      it "loads as a top-level constant from app/models/finance_sales/" do
        expect(model.name).to eq(model.name.demodulize) # resolving the constant also triggers the autoload
        path = Object.const_source_location(model.name).first
        expect(path).to eq(Rails.root.join("app/models/finance_sales/#{model.name.underscore}.rb").to_s)
      end

      it "no longer has a top-level model file" do
        expect(File).not_to exist(Rails.root.join("app/models/#{model.name.underscore}.rb"))
      end

      it "keeps #{table} as its table and its stored type name" do
        expect(model.table_name).to eq(table)
        expect(model.polymorphic_name).to eq(model.name)
      end

      it "is not namespaced under FinanceSales" do
        expect(defined?(::FinanceSales)).to be_nil.or(satisfy { !::FinanceSales.const_defined?(model.name, false) })
      end
    end
  end

  it "is the same class every association resolves" do
    {
      [ Business, :expenses ] => Expense, [ Business, :expense_categories ] => ExpenseCategory,
      [ Business, :expense_types ] => ExpenseType, [ Business, :expense_tags ] => ExpenseTag,
      [ Business, :recurring_expenses ] => RecurringExpense,
      [ Branch, :expenses ] => Expense, [ Branch, :expense_allocations ] => ExpenseAllocation,
      [ Branch, :recurring_expenses ] => RecurringExpense,
      [ Expense, :expense_category ] => ExpenseCategory, [ Expense, :expense_type ] => ExpenseType,
      [ Expense, :source_recurring_expense ] => RecurringExpense, [ Expense, :expense_allocations ] => ExpenseAllocation,
      [ Expense, :expense_taggings ] => ExpenseTagging, [ Expense, :expense_tags ] => ExpenseTag,
      [ ExpenseAllocation, :expense ] => Expense,
      [ ExpenseCategory, :expense_types ] => ExpenseType, [ ExpenseCategory, :expenses ] => Expense,
      [ ExpenseCategory, :recurring_expenses ] => RecurringExpense,
      [ ExpenseType, :expense_category ] => ExpenseCategory, [ ExpenseType, :expenses ] => Expense,
      [ ExpenseType, :recurring_expenses ] => RecurringExpense,
      [ ExpenseTag, :expense_taggings ] => ExpenseTagging, [ ExpenseTag, :expenses ] => Expense,
      [ ExpenseTagging, :expense ] => Expense, [ ExpenseTagging, :expense_tag ] => ExpenseTag,
      [ RecurringExpense, :expense_category ] => ExpenseCategory, [ RecurringExpense, :expense_type ] => ExpenseType,
      [ RecurringExpense, :recurring_expense_allocations ] => RecurringExpenseAllocation,
      [ RecurringExpense, :generated_expenses ] => Expense,
      [ RecurringExpenseAllocation, :recurring_expense ] => RecurringExpense,
      [ CustodyTransaction, :expense ] => Expense, [ PosImport, :generated_expenses ] => Expense
    }.each do |(owner, name), klass|
      expect(owner.reflect_on_association(name).klass).to equal(klass), "#{owner}##{name}"
    end
  end

  it "resolves to the moved classes from every non-polymorphic association in the app" do
    Rails.application.eager_load!
    names = models.keys.map(&:name)
    resolved = ApplicationRecord.descendants.flat_map do |owner|
      owner.reflect_on_all_associations.reject(&:polymorphic?)
           .select { |reflection| names.include?(reflection.class_name.delete_prefix("::")) }
           .map { |reflection| [ "#{owner}##{reflection.name}", reflection.klass ] }
    end

    expect(resolved.size).to be >= 32
    resolved.each { |label, klass| expect(models.keys).to include(klass), label }
  end
end
