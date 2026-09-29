# Employee data requests now carry the rest of the employee's basic data, so
# approval can create the employee without anyone re-entering it. Columns are
# named exactly like their users.* counterparts (the approved values are copied
# 1:1 onto the employee); nothing new is added to users.
#
# source distinguishes a manager's submission from a reviewer's correction —
# both are immutable revisions, so the audit trail shows submitted vs corrected.
class AddEmployeeFieldsToEmployeeDataRequestRevisions < ActiveRecord::Migration[8.1]
  def change
    change_table :employee_data_request_revisions, bulk: true do |t|
      t.date   :identity_card_expiry_date
      t.string :job_title
      t.date   :hire_date
      t.string :emergency_contact_name
      t.string :emergency_contact_phone
      t.string :emergency_contact_relationship
      t.string :source, null: false, default: "submission"
    end
  end
end
