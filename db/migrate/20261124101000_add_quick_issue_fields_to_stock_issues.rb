# Quick Issue (approved design): which workflow produced a Stock Issue, and
# the transaction's fixed reason (one per Quick Issue; "other" needs a
# description). Existing rows become workflow = "standard" through the column
# default — no other backfill: Quick Issues posted before this migration keep
# their "quick_issue: true" approval audit entry and no reason (none was ever
# recorded), so the reason requirement applies only to rows written as
# workflow "quick_issue" from now on (the check below cannot be violated by
# existing rows, which are all "standard").
class AddQuickIssueFieldsToStockIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :stock_issues, :workflow, :string, null: false, default: "standard"
    add_column :stock_issues, :issue_reason, :string
    add_column :stock_issues, :issue_reason_note, :text

    add_check_constraint :stock_issues, "workflow IN ('standard', 'quick_issue')",
                         name: "stock_issues_workflow_check"
    add_check_constraint :stock_issues,
                         "issue_reason IS NULL OR issue_reason IN ('internal_use', 'damaged', 'expired', 'lost', 'other')",
                         name: "stock_issues_issue_reason_check"
    add_check_constraint :stock_issues, "workflow <> 'quick_issue' OR issue_reason IS NOT NULL",
                         name: "stock_issues_quick_issue_reason_required"
    add_check_constraint :stock_issues,
                         "issue_reason IS DISTINCT FROM 'other' OR btrim(coalesce(issue_reason_note, '')) <> ''",
                         name: "stock_issues_other_reason_note_required"
  end
end
