# Composition root for the OrganizationAccess::MembershipProvider contract:
# Organization & Access defines it, Workforce implements it. Wired here so
# neither domain names the other (module-boundaries.md §12.1). to_prepare
# re-registers after a code reload in development.
# See docs/architecture/next-pilot-selection.md (Pilot 5 — membership contract, §20, M2).
Rails.application.config.to_prepare do
  OrganizationAccess::MembershipProvider.register(Workforce::MembershipProvider)
end
