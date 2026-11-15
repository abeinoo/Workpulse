# Composition root for the Employee::ExportColumns contract: Workforce defines it
# (the Employee Data Export asks for its salary columns), Attendance & Payroll
# implements it. Wired here so neither domain names the other
# (module-boundaries.md §12.1). to_prepare re-registers after a code reload in
# development.
Rails.application.config.to_prepare do
  Employee::ExportColumns.register(Payroll::EmployeeExportSalaryColumns)
end
