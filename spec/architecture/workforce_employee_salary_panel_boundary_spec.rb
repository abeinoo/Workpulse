require "rails_helper"

# Boundary for SAL — the Workforce employee page receives Attendance & Payroll's
# salary card only through the UI-composition contract Employee::ProfilePanels
# (module-boundaries.md §12.1; docs/architecture/workforce-employee-salary-panel-baseline-failures.txt).
#
# Rules:
# 1. The employee page's controller and views name no salary constant or table
#    (SalaryProfile, SalaryProfilePolicy, Salary::*, salary_profiles) and none of
#    the panel's former instance variables.
# 2. The page asks for the panel exactly once, in the controller, and renders it
#    only from @salary_panel.
# 3. The contract names nothing from Attendance & Payroll; the implementation is
#    named only by the composition root and is the registered handler; the card
#    partial lives in Attendance & Payroll's salary-profile views.
module ArchitectureSpecs
  module WorkforceEmployeeSalaryPanelBoundary
    module_function

    PAGE_FILES = %w[app/controllers/admin/users_controller.rb] +
                 Dir.glob("app/views/admin/users/**/*.erb", base: Rails.root.to_s).sort
    CONTRACT_FILE    = "app/services/employee/profile_panels.rb".freeze
    IMPLEMENTATION   = "app/services/payroll/employee_salary_panel.rb".freeze
    COMPOSITION_ROOT = "config/initializers/employee_profile_panels.rb".freeze
    PARTIAL          = "app/views/admin/salary_profiles/_employee_panel.html.erb".freeze

    SALARY = /\bSalaryProfile(Policy)?\b|\bSalary::|\bsalary_profiles?\b(?!\.|_path|_url)|@(salary_visible|salary_manageable|active_salary_profile)\b/

    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1).reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""').sub(/\s#\s.*$/, ""), number ] }
    end

    def matches_in(path, pattern) = code_lines(path).filter_map { |l, n| "#{path}:#{n}: #{l.strip}" if l.match?(pattern) }

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { _1.delete_prefix("#{Rails.root}/") }.sort
    end
  end
end

RSpec.describe "Architecture: the Workforce employee page gets the salary card only through Employee::ProfilePanels (SAL)" do
  boundary = ArchitectureSpecs::WorkforceEmployeeSalaryPanelBoundary

  it "the page names no salary constant, table or former panel variable (rule 1)" do
    found = boundary::PAGE_FILES.flat_map { boundary.matches_in(_1, boundary::SALARY) }
    expect(found).to be_empty, "Use Employee::ProfilePanels:\n#{found.join("\n")}"
  end

  it "the controller asks once and the view renders only @salary_panel (rule 2)" do
    calls = boundary::PAGE_FILES.flat_map { boundary.matches_in(_1, /Employee::ProfilePanels\.\w+/) }
    expect(calls.map { _1.split(":").first }).to eq([ "app/controllers/admin/users_controller.rb" ])
    expect(calls.first).to match(/Employee::ProfilePanels\.salary_panel\(viewer: current_user, employee: @user\)/)
    expect(boundary.matches_in("app/views/admin/users/show.html.erb", /@salary_panel/).size).to eq(2)
  end

  it "the contract, implementation, composition root and partial are where they belong (rule 3)" do
    expect(boundary.matches_in(boundary::CONTRACT_FILE, /\bSalary|Payroll|salary_profiles/)).to be_empty
    outside = (boundary.source_files + boundary.source_files("config"))
              .reject { [ boundary::IMPLEMENTATION, boundary::COMPOSITION_ROOT ].include?(_1) }
              .flat_map { boundary.matches_in(_1, /\bPayroll::EmployeeSalaryPanel\b/) }
    expect(outside).to be_empty
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                               /Employee::ProfilePanels\.register\(Payroll::EmployeeSalaryPanel\)/)).to be_present
    expect(Employee::ProfilePanels.handler).to equal(Payroll::EmployeeSalaryPanel)
    expect(File).to exist(Rails.root.join(boundary::PARTIAL))
    expect(File.read(Rails.root.join(boundary::IMPLEMENTATION))).to include('"admin/salary_profiles/employee_panel"')
  end

  describe "self-tests" do
    it "catches the former reads planted back, and ignores route helpers, i18n keys and comments" do
      [ "probe = SalaryProfile.new(user_id: @user.id)", "Salary::ViewAudit.record(actor: a)",
        "<% if @salary_visible || @salary_manageable %>", "policy_scope(SalaryProfile)" ].each do |code|
        expect(code).to match(boundary::SALARY), code
      end
      [ "new_admin_user_salary_profile_path(@user)", "t(\"salary_profiles.type\")", "# SalaryProfile in a comment" ].each do |code|
        line = code.gsub(/"(?:[^"\\]|\\.)*"/, '""').sub(/\A#.*/, "")
        expect(line).not_to match(boundary::SALARY), code
      end
    end
  end
end
