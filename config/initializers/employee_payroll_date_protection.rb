# Composition root for the Employee::PayrollDateProtection contract (R3.2;
# roadmap revision 19, OD-1): Workforce defines it, Attendance & Payroll
# implements it. Wired here so neither domain names the other
# (module-boundaries.md §12.1). to_prepare re-registers after a code reload in
# development.
Rails.application.config.to_prepare do
  Employee::PayrollDateProtection.register(Payroll::RequirementDateProtection)
end
