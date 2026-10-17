# Composition root for the Requests::PunchCorrectionEffects contract: Workforce
# defines it, Attendance & Payroll implements it. Wired here so neither domain
# names the other (module-boundaries.md §12.1). to_prepare re-registers after a
# code reload in development.
# See docs/architecture/next-pilot-selection.md (Pilot 10 — Punch Correction, §25, M2).
Rails.application.config.to_prepare do
  Requests::PunchCorrectionEffects.register(Attendance::PunchCorrectionEffects)
end
