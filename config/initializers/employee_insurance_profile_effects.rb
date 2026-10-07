# Composition root for the Employee::InsuranceProfileEffects contract: Workforce
# defines it, Attendance & Payroll implements it. Wired here so neither domain
# names the other (module-boundaries.md §12.1). to_prepare re-registers after a
# code reload in development.
# See docs/architecture/next-pilot-selection.md (Pilot 8 — Employee Insurance Profile, §23, M2).
Rails.application.config.to_prepare do
  Employee::InsuranceProfileEffects.register(Payroll::InsuranceProfileEffects)
end
