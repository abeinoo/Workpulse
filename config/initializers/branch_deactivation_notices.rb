# Composition root for the OrganizationAccess::BranchDeactivationNotices
# contract: Organization & Access defines it (the branch deactivation dialog asks
# for its notices); Laundry implements the towel notice and Attendance & Payroll
# the biometric-device notice. Wired here so neither Organization & Access nor
# the providers name each other (module-boundaries.md §12.1). One call registers
# the complete list, in dialog order; to_prepare re-registers that same list
# after a code reload in development, replacing it, never appending. BUG-029.
Rails.application.config.to_prepare do
  OrganizationAccess::BranchDeactivationNotices.register(
    Laundry::BranchDeactivationNotice,
    Attendance::BranchDeactivationNotice
  )
end
