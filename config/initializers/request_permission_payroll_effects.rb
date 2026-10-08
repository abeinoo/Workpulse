# Composition root for the Requests::PermissionPayrollEffects contract: Workforce
# defines it, Attendance & Payroll implements it. Wired here so neither domain
# names the other (module-boundaries.md §12.1). to_prepare re-registers after a
# code reload in development.
# See docs/architecture/next-pilot-selection.md (Pilot 9 — Request Permission Payroll Effects, §24, M2).
Rails.application.config.to_prepare do
  Requests::PermissionPayrollEffects.register(Payroll::PermissionPayrollEffects)
end
