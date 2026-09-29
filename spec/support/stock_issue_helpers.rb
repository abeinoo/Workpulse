# Inventory::StockIssuePoster only ever posts an APPROVED stock issue (the
# approval gate — see StockIssue#issued_only_from_approved). Specs that just
# need a real, posted issue as a fixture (reports, ledgers, voiding, …) go
# through this helper instead of calling the poster on a draft: it marks the
# issue approved, persists it, then posts it with the real poster. Returns the
# poster's Result, exactly like calling the poster directly.
module StockIssueHelpers
  def approve_and_post_stock_issue(issue)
    issue.status = :approved
    issue.save!
    Inventory::StockIssuePoster.new(issue).call
  end

  # Persists `issue` in `status` for workflow/policy specs that only care
  # about the state, not real stock movements. "issued" is reachable only
  # from a persisted "approved" issue, so it is saved as approved first —
  # the same transition the real workflow makes.
  def save_stock_issue_in_status!(issue, status)
    if status.to_s == "issued"
      issue.status = :approved
      issue.save!
    end
    issue.status = status
    issue.save!
    issue
  end
end

RSpec.configure { |config| config.include StockIssueHelpers }

# `expect { … }.to change(A, :count).and not_change(B, :count)`
RSpec::Matchers.define_negated_matcher :not_change, :change unless RSpec::Matchers.method_defined?(:not_change)
