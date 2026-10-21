# Composition root for the Requests::RequestFormReads contract: Workforce defines
# it, Attendance & Payroll implements it. Wired here so neither domain names the
# other (module-boundaries.md §12.1). to_prepare re-registers after a code reload
# in development.
# See docs/architecture/workforce-request-validation-reads-baseline-failures.txt (Batch V — D-A5).
Rails.application.config.to_prepare do
  Requests::RequestFormReads.register(Payroll::RequestFormReads)
end
