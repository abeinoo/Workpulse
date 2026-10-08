class AddSubmittedByToEmployeeRequests < ActiveRecord::Migration[8.1]
  # submitted_by_id: the user who actually created / submitted the request —
  # distinct from user_id, the employee the request is FOR. An approver who
  # submits a request on behalf of an employee may not approve it (SEC-P10-1,
  # Pilot 10 unblock); the self-approval rule compares the approver with both.
  #
  # Nullable on purpose: existing requests carry no reliable record of who
  # created them (creation was never audited), so there is nothing safe to
  # backfill from. NULL means "submitter unknown (legacy)"; for those rows the
  # self-approval rule keeps its previous meaning (the employee). Every request
  # created from now on gets a submitter (Requests::Submitter, the model default).
  def change
    add_reference :employee_requests, :submitted_by, null: true, index: true,
                                                     foreign_key: { to_table: :users }
  end
end
