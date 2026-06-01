# WorkPulse Project Memory

- [Payroll Review Workflow](payroll_review_workflow.md) — Full lifecycle: draft→under_review→branch_review_completed→finalized→paid; new models, services, routes, policies added May 2026
- [i18n / RTL Implementation](i18n_rtl_implementation.md) — Full EN+AR localization, RTL CSS, language switcher in sidebar, default_locale on Business, preferred_locale on User
- [Permission Roles System](permission_roles_system.md) — Dynamic Fresha-style roles: PermissionRole model, User#can?, 9 permission groups, 21 keys, admin UI, 7 default seeds, full EN+AR i18n
- [Theme: Light/Dark System](theme_light_dark_system.md) — NO Tailwind; custom CSS-variable design system in application.css (dark-by-default). Light/dark via html.light token remap + class strategy, no-flash head script, theme_controller.js (June 2026)
