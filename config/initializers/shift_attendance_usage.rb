# Composition root for the Shifts::AttendanceUsage contract: Workforce defines it,
# Attendance & Payroll implements it. Wired here so neither domain names the other
# (module-boundaries.md §12.1). to_prepare re-registers after a code reload in
# development. See docs/architecture/workforce-shift-assignment-attendance-baseline-failures.txt (F2).
Rails.application.config.to_prepare do
  Shifts::AttendanceUsage.register(Attendance::ShiftAssignmentUsage)
end
