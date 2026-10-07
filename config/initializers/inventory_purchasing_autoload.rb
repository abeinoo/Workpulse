# Inventory & Purchasing models live in app/models/inventory_purchasing/ but keep
# their top-level constants (e.g. Supplier; table suppliers): the directory is
# collapsed, so it groups files without adding a namespace — and without
# touching the Inventory:: controller / service namespace.
# See docs/architecture/next-pilot-selection.md (Pilot 6 — Supplier, §21, M7).
Rails.autoloaders.main.collapse(Rails.root.join("app/models/inventory_purchasing"))
