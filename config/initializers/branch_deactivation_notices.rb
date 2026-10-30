# Composition root for the OrganizationAccess::BranchDeactivationNotices
# contract: Organization & Access defines it (the branch deactivation dialog asks
# for its notices), Laundry implements the towel notice. Wired here so neither
# domain names the other (module-boundaries.md §12.1). to_prepare re-registers
# after a code reload in development. BUG-029.
Rails.application.config.to_prepare do
  OrganizationAccess::BranchDeactivationNotices.register(Laundry::BranchDeactivationNotice)
end
