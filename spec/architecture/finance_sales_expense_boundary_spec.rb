require "rails_helper"

# Boundary enforcement for Milestone 2 — Finance & Sales Expenses (M6; see
# docs/architecture/next-pilot-selection.md §18).
#
# Two boundaries, both taken from the post-M4 dependency graph:
#
# 1. The Expenses group — Expense, ExpenseAllocation, ExpenseCategory,
#    ExpenseType, ExpenseTag, ExpenseTagging, RecurringExpense,
#    RecurringExpenseAllocation and their Finance services — is owned by
#    Finance & Sales. Other domains must not reach its internals (the classes,
#    the services, the collections and tables) outside the documented
#    exceptions. Reporting reads are listed separately and must stay read-only.
#
# 2. The payroll insurance path (cycle F3, removed in M4). Attendance & Payroll
#    reaches Finance only through its own Payroll::FinalizationEffects contract,
#    wired to Finance::PayrollFinalizationEffects in
#    config/initializers/payroll_finalization_effects.rb. Payroll computes the
#    employer insurance cost (Payroll::EmployerInsuranceCost); Finance owns the
#    expense (Finance::PayrollInsuranceExpense) and reads no payroll entries or
#    shift assignments.
#
# Not guarded: route helpers (finance_expenses_path …), i18n keys
# ("finance.expenses.title"), the expense permissions (view_expenses …), hash
# keys and locals named `expenses` (profitability metrics), Inventory::
# NumberSequencer, and config/ (routes, locales), as in the other boundary specs.
#
# This spec fails on any NEW direct reference outside the allow-lists below.
# Adding to an allow-list is an architectural decision: give the reason.
module ArchitectureSpecs
  module FinanceSalesExpenseBoundary
    module_function

    FORBIDDEN = /
      \b(?:Recurring)?Expense(?:Allocation|Category|Type|Tag|Tagging)?\b       # the models (not ExpensePolicy …)
      | \b(?:ExpenseApproval|ExpensePaymentRecorder|RecurringExpenseGenerator
           |AllocationCalculator|PayrollInsuranceExpense|PayrollFinalizationEffects
           |GenerateDueRecurringExpensesJob)\b                                  # Finance services and job
      | \.(?:recurring_)?expenses\b                                             # collections: business.expenses
      | \b(?:has_many|has_one|belongs_to)\s+:(?:recurring_)?expense             # association declarations
      | \bexpense_(?:allocations|categories|types|tags|taggings)\b              # collections and tables
      | \brecurring_expenses?\b | \brecurring_expense_allocations\b
    /x

    # Finance & Sales namespaces (module-boundaries.md §8), minus the Reporting files below.
    FINANCE_SALES_DIRS = [
      "app/controllers/finance/",
      "app/services/finance/",
      "app/views/finance/",
      "app/jobs/finance/"
    ].freeze

    # Finance & Sales models and policies outside a finance/ folder (module-boundaries.md §10).
    FINANCE_SALES_FILES = {
      "app/models/finance_sales/expense.rb"                      => "the model itself",
      "app/models/finance_sales/expense_allocation.rb"           => "the model itself",
      "app/models/finance_sales/expense_category.rb"             => "the model itself",
      "app/models/finance_sales/expense_type.rb"                 => "the model itself",
      "app/models/finance_sales/expense_tag.rb"                  => "the model itself",
      "app/models/finance_sales/expense_tagging.rb"              => "the model itself",
      "app/models/finance_sales/recurring_expense.rb"            => "the model itself",
      "app/models/finance_sales/recurring_expense_allocation.rb" => "the model itself",
      "app/models/custody_transaction.rb"          => "FS custody: belongs_to :expense (expense paid from custody)",
      "app/models/financial_settlement.rb"         => "FS settlements: Expense is a settleable type",
      "app/models/pos_import.rb"                   => "FS sales: has_many :generated_expenses (POS fee expenses)",
      "app/policies/expense_policy.rb"             => "FS expense policy",
      "app/policies/recurring_expense_policy.rb"   => "FS recurring-expense policy"
    }.freeze

    # Reporting (module-boundaries.md §9): cross-domain dashboards that read expenses. Read-only.
    REPORTING_DIRS = [
      "app/services/finance/dashboard/",
      "app/views/finance/dashboard/"
    ].freeze

    REPORTING_FILES = {
      "app/controllers/finance/dashboard_controller.rb" => "Reporting: finance dashboard reads approved expenses (policy_scope)",
      "app/services/finance/dashboard_filters.rb"       => "Reporting: dashboard filter validates Expense::PAYMENT_SOURCES",
      "app/services/finance/reports/expense_sources.rb" => "Reporting: profitability expense sources (direct + shared allocations)",
      "app/services/finance/reports/laundry_cost_summary.rb" => "Reporting: laundry operating cost reads approved expenses (Pilot 11)"
    }.freeze

    # Cross-domain exceptions documented in the Expenses M0 classification.
    EXCEPTION_FILES = {
      "app/models/business.rb"                         => "Organization & Access inverse associations (has_many :expenses …)",
      "app/models/branch.rb"                           => "Organization & Access inverse associations (restrict_with_error)",
      "app/helpers/workspace_helper.rb"                => "UI shell: Finance workspace nav gated by policy(Expense …)"
    }.freeze

    READ_ONLY_EXCEPTIONS = [].freeze

    WRITE_CALL = /\.(?:create|update|update_all|update_columns?|save|destroy|destroy_all|delete|delete_all|
                    insert_all|upsert_all|build|find_or_create_by|increment|decrement|toggle)!?(?=[(\s]|$)/x

    def allowed_files = FINANCE_SALES_FILES.merge(REPORTING_FILES).merge(EXCEPTION_FILES)

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Full-line Ruby comments, ERB comments (including multi-line) and t(...)
    # i18n keys (t("finance.expenses.title")) are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/\b(?:I18n\.)?t\(\s*(["'])[^"']*\1/, 't("KEY"'), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def violations_in(path) = matches_in(path, FORBIDDEN)

    def reporting?(path)
      REPORTING_FILES.key?(path) || REPORTING_DIRS.any? { |dir| path.start_with?(dir) }
    end

    def read_only_files = source_files.select { |path| reporting?(path) } + READ_ONLY_EXCEPTIONS

    def allowed?(path)
      allowed_files.key?(path) || reporting?(path) || FINANCE_SALES_DIRS.any? { |dir| path.start_with?(dir) }
    end
  end

  module FinanceSalesPayrollInsurancePath
    module_function

    # Attendance & Payroll code (module-boundaries.md §6 / §10).
    ATTENDANCE_PAYROLL_GLOBS = %w[
      app/models/attendance_payroll/**/*.rb
      app/models/{advance,attendance_*,payroll_*,penalty_rule,salary_profile}.rb
      app/services/{payroll,attendance,salary}/**/*.rb
      app/jobs/payroll/**/*.rb
      app/controllers/{attendance,attendance_records,payroll_*}_controller.rb
      app/controllers/admin/{attendance_imports,attendance_records,biometric_*,employee_obligations,penalty_rules,salary_profiles}_controller.rb
      app/controllers/api/v1/{attendance,attendance_records,biometric_base,payroll_*,punches,salary_profiles}_controller.rb
      app/views/{attendance_records,payroll_*}/**/*.erb
      app/views/admin/{attendance_imports,attendance_records,biometric_*,employee_obligations,penalty_rules,salary_profiles}/**/*.erb
      app/policies/{advance,attendance_*,biometric_device,employee_obligation,payroll_*,penalty_rule,salary_profile}_policy.rb
    ].freeze

    # Anything Finance: the namespace, the Expenses group, and number sequencing.
    FINANCE_IN_PAYROLL = Regexp.union(/\bFinance::/, /\bNumberSequencer\b/, FinanceSalesExpenseBoundary::FORBIDDEN)

    # Payroll internals and the Workforce assignment read that only Payroll may use to compute the cost.
    PAYROLL_COST_INPUTS = /
      \bPayrollEntry\b | \bpayroll_entries\b | \bPayrollLineItem\b | \bpayroll_line_items\b
      | \bShiftAssignment\b | \bshift_assignments\b | \bbranch_ids_by_user\b
      | \bEmployerInsuranceCost\b | \bemployer_insurance_amount\b
    /x

    # The Finance side of the insurance path.
    FINANCE_INSURANCE_FILES = %w[
      app/services/finance/payroll_finalization_effects.rb
      app/services/finance/payroll_insurance_expense.rb
    ].freeze

    COMPOSITION_ROOT = "config/initializers/payroll_finalization_effects.rb".freeze

    def payroll_files
      ATTENDANCE_PAYROLL_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }
                              .map { |f| f.delete_prefix("#{Rails.root}/") }.uniq.sort
    end

    def payroll_file?(path) = payroll_files.include?(path)
  end
end

RSpec.describe "Architecture: Finance & Sales expense boundary" do
  boundary = ArchitectureSpecs::FinanceSalesExpenseBoundary

  it "has no direct Expenses access outside Finance & Sales, Reporting reads and the documented exceptions" do
    violations = boundary.source_files.reject { |path| boundary.allowed?(path) }.flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Direct access to Finance & Sales expense internals from outside the domain:
      #{violations.join("\n")}
      Go through Finance & Sales code, or document a new exception in
      next-pilot-selection.md (§18, Finance & Sales Expenses) and the allow-list.
    MSG
  end

  it "keeps Reporting and the laundry cost report read-only on expenses" do
    writes = boundary.read_only_files.flat_map { |path| boundary.violations_in(path) }.grep(boundary::WRITE_CALL)
    expect(writes).to be_empty, "Reporting must not write Finance & Sales expenses:\n#{writes.join("\n")}"
  end

  it "keeps the allow-list tight (every listed file exists and still needs its entry)" do
    stale = boundary.allowed_files.keys.select { |path| !File.exist?(Rails.root.join(path)) || boundary.violations_in(path).empty? }
    expect(stale).to be_empty, "Remove from the allow-list: #{stale.join(', ')}"
  end

  it "keeps every allowed directory in use" do
    unused = (boundary::FINANCE_SALES_DIRS + boundary::REPORTING_DIRS).reject do |dir|
      boundary.source_files.any? { |path| path.start_with?(dir) && boundary.violations_in(path).any? }
    end
    expect(unused).to be_empty, "Remove from the allowed directories: #{unused.join(', ')}"
  end

  describe "self-tests" do
    it "allows Finance & Sales, Reporting and documented exceptions, and rejects any other domain" do
      expect(boundary.allowed?("app/services/finance/expense_approval.rb")).to be(true)
      expect(boundary.allowed?("app/models/finance_sales/expense.rb")).to be(true)
      expect(boundary.allowed?("app/views/finance/dashboard/_kpi_cards.html.erb")).to be(true)
      expect(boundary.reporting?("app/views/finance/dashboard/_kpi_cards.html.erb")).to be(true)
      expect(boundary.allowed?("app/models/business.rb")).to be(true)
      expect(boundary.allowed?("app/services/payroll/approver.rb")).to be(false)
      expect(boundary.allowed?("app/services/inventory/goods_receipt_poster.rb")).to be(false)
      expect(boundary.allowed?("app/controllers/admin/users_controller.rb")).to be(false)
    end

    it "matches every guarded constant, service, collection and table" do
      [
        "Expense.where(id: ids)", "ExpenseAllocation.create!(attrs)", "ExpenseCategory.find(id)",
        "ExpenseType.active", "ExpenseTag.where(name: n)", "ExpenseTagging.new", "RecurringExpense.due",
        "RecurringExpenseAllocation.all", "Finance::ExpenseApproval.call(**args)",
        "Finance::ExpensePaymentRecorder.new(e)", "Finance::RecurringExpenseGenerator.call",
        "Finance::AllocationCalculator.new", "Finance::PayrollInsuranceExpense.record(**args)",
        "Finance::PayrollFinalizationEffects.period_finalized(**args)", "business.expenses.approved",
        "has_many :expenses", "belongs_to :expense", "business.expense_categories.find_by(name: n)",
        "joins(:expense_allocations)", "@business.recurring_expenses", 'class_name: "Expense"'
      ].each { |code| expect(code).to match(boundary::FORBIDDEN), code }
    end

    it "is not so broad that it guards policies, routes, permissions, i18n keys or metric keys" do
      [
        "authorize ExpensePolicy", "finance_expenses_path(filters)", "finance_recurring_expenses_path",
        "user.can?(:view_expenses)", "row[:expenses]", "expenses: summary[:total]", "%i[revenue expenses net]",
        "expenses = totals.sum", "Inventory::NumberSequencer.new(b, :goods_receipt)", "@expense.amount"
      ].each { |code| expect(code).not_to match(boundary::FORBIDDEN), code }
    end

    it "flags a guarded reference in a file outside the allow-list" do
      external = "app/services/inventory/hypothetical.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(external)).and_return("Expense.sum(:amount)\n")

      expect(boundary.allowed?(external)).to be(false)
      expect(boundary.violations_in(external)).to eq([ "#{external}:1: Expense.sum(:amount)" ])
    end

    it "ignores guarded names in comments and i18n keys" do
      path = "app/services/hypothetical_comment.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path))
        .and_return("# Expense is FS-owned\nlabel = t(\"finance.expenses.title\")\n")

      expect(boundary.violations_in(path)).to be_empty
    end

    it "detects a write in a read-only file" do
      expect("@business.expenses.create!(amount: 1)").to match(boundary::WRITE_CALL)
      expect("@business.expenses.where(status: s).sum(:amount)").not_to match(boundary::WRITE_CALL)
      expect("policy(Expense).new?").not_to match(boundary::WRITE_CALL)
    end
  end
end

RSpec.describe "Architecture: payroll insurance path (Attendance & Payroll ↔ Finance & Sales)" do
  path     = ArchitectureSpecs::FinanceSalesPayrollInsurancePath
  boundary = ArchitectureSpecs::FinanceSalesExpenseBoundary

  it "covers every Attendance & Payroll glob (no stale glob)" do
    empty = path::ATTENDANCE_PAYROLL_GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
  end

  it "Attendance & Payroll names no Finance class, expense internal or NumberSequencer" do
    violations = path.payroll_files.flat_map { |file| boundary.matches_in(file, path::FINANCE_IN_PAYROLL) }
    expect(violations).to be_empty, <<~MSG
      Attendance & Payroll must reach Finance & Sales only through Payroll::FinalizationEffects:
      #{violations.join("\n")}
    MSG
  end

  it "Payroll reaches Finance through Payroll::FinalizationEffects in the Approver and Reopener" do
    approver = boundary.code_lines("app/services/payroll/approver.rb").map(&:first).join
    reopener = boundary.code_lines("app/services/payroll/reopener.rb").map(&:first).join

    expect(approver).to include("Payroll::EmployerInsuranceCost.for(@period)", "Payroll::FinalizationEffects.period_finalized(")
    expect(reopener).to include("Payroll::FinalizationEffects.period_reopened(")
  end

  it "only the composition root and Finance name the Finance implementation of the contract" do
    sources   = boundary.source_files + boundary.source_files("config")
    reference = /\bFinance::PayrollFinalizationEffects\b|\bPayrollFinalizationEffects\b/
    outside   = sources.reject { |file| file.start_with?("app/services/finance/") || file == path::COMPOSITION_ROOT }
                       .flat_map { |file| boundary.matches_in(file, reference) }

    expect(outside).to be_empty, "Unexpected reference to the contract implementation:\n#{outside.join("\n")}"
    expect(boundary.matches_in(path::COMPOSITION_ROOT, /Payroll::FinalizationEffects\.register\(Finance::PayrollFinalizationEffects\)/))
      .to be_present
  end

  it "registers Finance::PayrollFinalizationEffects as the contract implementation" do
    expect(Payroll::FinalizationEffects.handler).to equal(Finance::PayrollFinalizationEffects)
    expect(Payroll::FinalizationEffects::OPERATIONS).to all(satisfy { |op| Finance::PayrollFinalizationEffects.respond_to?(op) })
  end

  it "Finance computes nothing from payroll entries or shift assignments on the insurance path" do
    violations = path::FINANCE_INSURANCE_FILES.flat_map { |file| boundary.matches_in(file, path::PAYROLL_COST_INPUTS) }
    expect(violations).to be_empty, "The insurance cost must arrive from Payroll as data:\n#{violations.join("\n")}"
  end

  it "keeps the employer insurance calculation in Attendance & Payroll" do
    cost = "app/services/payroll/employer_insurance_cost.rb"
    expect(boundary.matches_in(cost, /payroll_entries|\.where\(insured: true\)/)).to be_present
    expect(boundary.matches_in(cost, /\bShiftAssignment\.branch_ids_by_user\b/)).to be_present

    callers = boundary.source_files.reject { |file| file == cost }
                      .flat_map { |file| boundary.matches_in(file, /\bEmployerInsuranceCost\b/) }
    expect(callers.map { |line| line.split(":").first }.uniq).to all(satisfy { |file| path.payroll_file?(file) })
  end

  it "keeps the allowed Finance → Payroll read: the expense's source payroll period" do
    association = Expense.reflect_on_association(:source_payroll_period)
    expect(association).to have_attributes(macro: :belongs_to, class_name: "PayrollPeriod")
    expect(association.options).to include(optional: true)
  end

  describe "self-tests" do
    it "flags a Finance reference planted in Attendance & Payroll code" do
      planted = "app/services/payroll/approver.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(planted))
        .and_return("Finance::PayrollInsuranceExpense.record(period: p, actor: a, total: t, by_branch: b)\n" \
                    "Finance::NumberSequencer.new(business, :expense).next_number\n" \
                    "business.expense_categories.find_by(name: n)\n" \
                    "# Finance::PayrollInsuranceExpense in a comment\n")

      expect(boundary.matches_in(planted, path::FINANCE_IN_PAYROLL).size).to eq(3)
    end

    it "flags a payroll read planted in the Finance insurance service" do
      planted = "app/services/finance/payroll_insurance_expense.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(planted))
        .and_return("@period.payroll_entries.where(insured: true)\nShiftAssignment.branch_ids_by_user(ids, from: f, to: t)\n")

      expect(boundary.matches_in(planted, path::PAYROLL_COST_INPUTS).size).to eq(2)
    end
  end
end
