# Finance & Sales models live in app/models/finance_sales/ but keep their
# top-level constants (e.g. Expense, ExpenseCategory; tables expenses,
# expense_categories): the directory is collapsed, so it groups files without
# adding a namespace.
# See docs/architecture/next-pilot-selection.md (Milestone 2 — Finance & Sales Expenses, §18, M7).
Rails.autoloaders.main.collapse(Rails.root.join("app/models/finance_sales"))
