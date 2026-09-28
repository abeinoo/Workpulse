# The reviewer's final punch for a punch correction is stored as ONE datetime
# (approved_punch_at) instead of a separate date column plus a time string.
# approved_date was introduced earlier the same day, never deployed and holds
# no data, so it is removed. The legacy approved_time string stays: historical
# approvals still reference it.
class ReplaceApprovedDateWithApprovedPunchAtOnEmployeeRequests < ActiveRecord::Migration[8.1]
  def change
    add_column    :employee_requests, :approved_punch_at, :datetime
    remove_column :employee_requests, :approved_date, :date
  end
end
