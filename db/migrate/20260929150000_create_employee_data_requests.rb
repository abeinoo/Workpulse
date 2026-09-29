# Employee data submission ("طلب إضافة موظف"): a manager submits a new
# employee's basic personal data + ID photos for review, instead of sending
# them over WhatsApp. Only personal-data verification lives here — branch,
# salary, permissions, shifts and payroll are configured separately after
# approval.
#
# - employee_data_requests          — the aggregate: status + last decision.
# - employee_data_request_revisions — one immutable snapshot per submission
#                                     (initial + every resubmission), so the
#                                     submitted values are never overwritten.
# - employee_data_request_events    — append-only review history
#                                     (submitted / resubmitted / approved /
#                                     rejected / changes_requested + note).
#
# users.address is new: the approved address needs somewhere to live.
class CreateEmployeeDataRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :address, :text

    create_table :employee_data_requests do |t|
      t.references :business,     null: false, foreign_key: true
      t.references :submitted_by, null: false, foreign_key: { to_table: :users }
      t.string     :status,       null: false, default: "pending_review"
      t.references :reviewed_by,  foreign_key: { to_table: :users }
      t.datetime   :reviewed_at
      # The employee record created on approval (nil until approved).
      t.references :employee,     foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :employee_data_requests, [ :business_id, :status ]

    create_table :employee_data_request_revisions do |t|
      t.references :employee_data_request, null: false, foreign_key: true
      t.integer    :revision_number,       null: false
      t.references :submitted_by,          null: false, foreign_key: { to_table: :users }
      t.string     :full_name,             null: false
      t.string     :national_id,           null: false
      t.string     :phone_number,          null: false
      t.text       :address,               null: false
      t.date       :date_of_birth,         null: false
      t.text       :manager_notes
      t.datetime   :created_at,            null: false
    end
    add_index :employee_data_request_revisions, [ :employee_data_request_id, :revision_number ],
              unique: true, name: "index_edr_revisions_on_request_and_number"
    add_index :employee_data_request_revisions, :national_id

    create_table :employee_data_request_events do |t|
      t.references :employee_data_request, null: false, foreign_key: true
      t.references :actor,                 null: false, foreign_key: { to_table: :users }
      t.references :revision,              foreign_key: { to_table: :employee_data_request_revisions }
      t.string     :action,                null: false
      t.text       :note
      t.datetime   :created_at,            null: false
    end
  end
end
