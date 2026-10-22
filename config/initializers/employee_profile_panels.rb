# Composition root for the Employee::ProfilePanels contract: Workforce defines it
# (the employee page asks for its panels), Attendance & Payroll implements the
# salary panel. Wired here so neither domain names the other
# (module-boundaries.md §12.1). to_prepare re-registers after a code reload in
# development. See docs/architecture/workforce-employee-salary-panel-baseline-failures.txt (SAL).
Rails.application.config.to_prepare do
  Employee::ProfilePanels.register(Payroll::EmployeeSalaryPanel)
end
