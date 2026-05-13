class RemoveBranchFromEmployeeRequests < ActiveRecord::Migration[8.0]
  def up
    remove_index  :employee_requests, name: "index_employee_requests_on_branch_id_and_status", if_exists: true
    remove_index  :employee_requests, name: "index_employee_requests_on_branch_id",             if_exists: true
    remove_foreign_key :employee_requests, :branches
    remove_column :employee_requests, :branch_id
  end

  def down
    add_column      :employee_requests, :branch_id, :integer, null: false, default: 0
    add_index       :employee_requests, :branch_id
    add_index       :employee_requests, [ :branch_id, :status ]
    add_foreign_key :employee_requests, :branches
  end
end
