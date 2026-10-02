# Workforce models live in app/models/workforce/ but keep their top-level
# constants (e.g. Department, JobTitle; tables departments, job_titles): the
# directory is collapsed, so it groups files without adding a namespace.
# See docs/architecture/next-pilot-selection.md (decision D-WF2, M7).
Rails.autoloaders.main.collapse(Rails.root.join("app/models/workforce"))
