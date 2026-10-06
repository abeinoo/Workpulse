# Composition root for the Shifts::PenaltyRuleSettings contract: Workforce
# defines it, Attendance & Payroll implements it. Wired here so neither domain
# names the other (module-boundaries.md §12.1). to_prepare re-registers after a
# code reload in development.
# See docs/architecture/next-pilot-selection.md (Pilot 4 — Penalty Rules, §19, M2).
Rails.application.config.to_prepare do
  Shifts::PenaltyRuleSettings.register(Attendance::ShiftPenaltyRules)
end
