# Composition root for the OrganizationAccess::BranchTerminalSettings contract:
# Organization & Access defines it, Finance & Sales implements it. Wired here so
# neither domain names the other (module-boundaries.md §12.1). to_prepare
# re-registers after a code reload in development.
# See docs/architecture/next-pilot-selection.md (Pilot 12 — POS terminals write boundary, §27).
Rails.application.config.to_prepare do
  OrganizationAccess::BranchTerminalSettings.register(Finance::BranchPosTerminals)
end
