# Attendance & Payroll models live in app/models/attendance_payroll/ but keep
# their top-level constants (e.g. BiometricDevice, BiometricPunchLog; tables
# biometric_devices, biometric_punch_logs): the directory is collapsed, so it
# groups files without adding a namespace.
# See docs/architecture/next-pilot-selection.md (Milestone 2, Q-M2-1, M7).
Rails.autoloaders.main.collapse(Rails.root.join("app/models/attendance_payroll"))
