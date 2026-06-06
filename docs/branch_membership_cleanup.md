# Branch membership: remaining UserBranch cleanup

## Background

`ShiftAssignment` is the authoritative source of an employee's branch (attendance,
scheduling, check-in, dashboard presence). The legacy `UserBranch` join table is
**not populated by any runtime code** — only `db/seeds.rb`. In production it is
effectively empty, which caused the "Branch Only" payroll scope to return no
employees and the Complete Branch Review button to never appear.

## Migrated (done)

These paths now derive branch membership from active `ShiftAssignment` via the
helpers on `app/models/shift_assignment.rb` (`active_during`, `user_ids_for_branches`,
`branch_ids_for_users`, `branch_names_by_user`):

- `EmployeeScope#branch` (Branch Only scope) — `app/services/employee_scope.rb`
- Payroll branch attribution:
  - `Payroll::SubmitForReview#branches_needing_review` (branch-review creation)
  - `PayrollPeriodsController#load_user_branch_names`
  - `PayrollDashboardController#build_branch_costs`
  - `Payroll::InsightsPresenter`
  - `Payroll::RecommendationEngine#branch_data`
  - `PayrollAdjustment.for_branch`
  - `BulkAdjustmentsController#manageable_employees` (removed `includes(:user_branches)`)

## NOT migrated — future cleanup pass (to finish requirement 4)

Intentionally left on `UserBranch`/`User#branch_ids` to limit blast radius. Each
must move to shift-based membership before the model associations are dropped.

### EmployeeScope#relation (highest priority — shared infrastructure)
- `app/services/employee_scope.rb:38` — `relation` still matches
  `UserBranch.where(branch_id: ...)` **OR** `manager_id`. It currently works in
  production via the `manager_id` clause.
- Consumers (via `relation` / `for_scope` / `for_permission` / `for_permissions`):
  - `app/policies/attendance_record_policy.rb`
  - `app/policies/employee_request_policy.rb`
  - `app/policies/user_policy.rb`
  - `app/policies/salary_profile_policy.rb`
  - `app/policies/payroll_entry_policy.rb` (the no-explicit-scope branch)
  - `app/policies/application_policy.rb#filter_by_data_scope`
  - Note: switching `relation` to shift-based will change behavior for branch
    members who are not direct reports; all consumer specs that set up `UserBranch`
    will need `ShiftAssignment` setup.

### Dashboards
- `app/controllers/operations_dashboard_controller.rb:89-100`
- `app/services/dashboard/owner_data.rb:151-153`
- `app/services/dashboard/area_manager_data.rb:74-76, 202`
- `app/controllers/dashboard_controller.rb:95` (`current_user.branch_ids`)

### Requests / notifications
- `app/models/employee_request.rb:46-47` (`pending_for_branch`)
- `app/services/notifications/request_notifier.rb:83` (`requester.branch_ids`)
- `app/jobs/notifications/pending_approval_reminder_job.rb:56` (`requester.branch_ids`)

### Misc
- `app/controllers/shift_assignments_controller.rb:350` (`current_user.user_branches`)
- `app/controllers/admin/branches_controller.rb:40` (`UserBranch.where(branch:)`)
- `app/controllers/api/v1/reports/attendance_controller.rb:30` (`current_user.branch_ids`)

### Model associations (drop last, after all consumers migrate)
- `app/models/user.rb:37-38` — `has_many :user_branches`, `has_many :branches, through:`
- `app/models/branch.rb:5-6` — `has_many :user_branches`, `has_many :users, through:`
- Then: drop the `user_branches` table and `UserBranch` model, remove
  `db/seeds.rb` UserBranch creation and `spec/factories/user_branches.rb`.
