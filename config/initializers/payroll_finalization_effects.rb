# Composition root for the Payroll::FinalizationEffects contract: Attendance &
# Payroll defines it, Finance & Sales implements it. Wired here so neither
# domain names the other (module-boundaries.md §12.1). to_prepare re-registers
# after a code reload in development.
# See docs/architecture/next-pilot-selection.md (Milestone 2, §18, M2).
Rails.application.config.to_prepare do
  Payroll::FinalizationEffects.register(Finance::PayrollFinalizationEffects)
end
