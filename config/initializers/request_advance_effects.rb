# Composition root for the Requests::AdvanceEffects contract: Workforce defines
# it, Attendance & Payroll implements it. Wired here so neither domain names the
# other (module-boundaries.md §12.1). to_prepare re-registers after a code reload
# in development.
# See docs/architecture/next-pilot-selection.md (Batch A — Advance boundary, §30).
Rails.application.config.to_prepare do
  Requests::AdvanceEffects.register(Payroll::AdvanceEffects)
end
