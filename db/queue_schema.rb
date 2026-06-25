# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_25_100000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "advances", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "employee_request_id", null: false
    t.datetime "issued_at", null: false
    t.decimal "remaining_amount", precision: 12, scale: 2, null: false
    t.string "status", default: "active", null: false
    t.decimal "total_amount", precision: 12, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["employee_request_id"], name: "index_advances_on_employee_request_id", unique: true
    t.index ["user_id", "status"], name: "index_advances_on_user_id_and_status"
    t.index ["user_id"], name: "index_advances_on_user_id"
  end

  create_table "attendance_adjustments", force: :cascade do |t|
    t.integer "adjusted_by_id", null: false
    t.integer "attendance_record_id", null: false
    t.datetime "created_at", null: false
    t.string "field_name", null: false
    t.text "new_value"
    t.text "old_value"
    t.text "reason", null: false
    t.index ["adjusted_by_id"], name: "index_attendance_adjustments_on_adjusted_by_id"
    t.index ["attendance_record_id", "created_at"], name: "idx_on_attendance_record_id_created_at_e057bc440f"
    t.index ["attendance_record_id"], name: "index_attendance_adjustments_on_attendance_record_id"
  end

  create_table "attendance_import_logs", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.integer "failed_rows_count", default: 0, null: false
    t.string "filename", null: false
    t.bigint "imported_by_id", null: false
    t.integer "imported_rows", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "status", default: "pending", null: false
    t.integer "total_rows", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "created_at"], name: "index_attendance_import_logs_on_business_id_and_created_at"
    t.index ["business_id"], name: "index_attendance_import_logs_on_business_id"
    t.index ["imported_by_id"], name: "index_attendance_import_logs_on_imported_by_id"
  end

  create_table "attendance_records", force: :cascade do |t|
    t.integer "branch_id"
    t.datetime "check_in_at", null: false
    t.decimal "check_in_latitude", precision: 10, scale: 8
    t.decimal "check_in_longitude", precision: 11, scale: 8
    t.string "check_in_source"
    t.datetime "check_out_at"
    t.decimal "check_out_latitude", precision: 10, scale: 8
    t.decimal "check_out_longitude", precision: 11, scale: 8
    t.string "check_out_source"
    t.datetime "created_at", null: false
    t.integer "created_by_id"
    t.date "date", null: false
    t.integer "early_leave_minutes", default: 0, null: false
    t.integer "late_minutes", default: 0, null: false
    t.integer "overtime_minutes", default: 0, null: false
    t.integer "shift_assignment_id"
    t.string "status", default: "incomplete", null: false
    t.datetime "updated_at", null: false
    t.integer "updated_by_id"
    t.integer "user_id", null: false
    t.date "work_date", null: false
    t.integer "worked_minutes"
    t.index ["branch_id", "date"], name: "index_attendance_records_on_branch_id_and_date"
    t.index ["branch_id"], name: "index_attendance_records_on_branch_id"
    t.index ["check_in_source"], name: "index_attendance_records_on_check_in_source"
    t.index ["created_by_id"], name: "index_attendance_records_on_created_by_id"
    t.index ["shift_assignment_id"], name: "index_attendance_records_on_shift_assignment_id"
    t.index ["updated_by_id"], name: "index_attendance_records_on_updated_by_id"
    t.index ["user_id", "status"], name: "idx_att_records_user_status"
    t.index ["user_id", "status"], name: "index_attendance_records_on_user_id_and_status"
    t.index ["user_id", "work_date"], name: "idx_att_records_user_date"
    t.index ["user_id", "work_date"], name: "index_attendance_records_on_user_id_and_work_date", unique: true
    t.index ["user_id"], name: "index_attendance_records_on_user_id"
  end

  create_table "audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_id", null: false
    t.bigint "auditable_id", null: false
    t.string "auditable_type", null: false
    t.bigint "business_id", null: false
    t.jsonb "changes_json", default: {}, null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.index ["actor_id"], name: "index_audit_logs_on_actor_id"
    t.index ["auditable_type", "auditable_id"], name: "index_audit_logs_on_auditable"
    t.index ["business_id"], name: "index_audit_logs_on_business_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
  end

  create_table "balance_requests", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.bigint "branch_id"
    t.bigint "business_id", null: false
    t.text "cancellation_reason"
    t.datetime "cancelled_at"
    t.bigint "cancelled_by_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.text "notes", null: false
    t.datetime "paid_at"
    t.bigint "paid_by_id"
    t.string "reference_number"
    t.text "rejection_reason"
    t.date "request_date", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_balance_requests_on_approved_by_id"
    t.index ["branch_id"], name: "index_balance_requests_on_branch_id"
    t.index ["business_id", "status"], name: "index_balance_requests_on_business_id_and_status"
    t.index ["business_id"], name: "index_balance_requests_on_business_id"
    t.index ["cancelled_by_id"], name: "index_balance_requests_on_cancelled_by_id"
    t.index ["created_by_id"], name: "index_balance_requests_on_created_by_id"
    t.index ["paid_by_id"], name: "index_balance_requests_on_paid_by_id"
    t.index ["reference_number"], name: "index_balance_requests_on_reference_number", unique: true, where: "(reference_number IS NOT NULL)"
  end

  create_table "bank_accounts", force: :cascade do |t|
    t.string "account_name", null: false
    t.boolean "active", default: true, null: false
    t.string "bank_name", null: false
    t.bigint "branch_id", null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["branch_id", "active"], name: "index_bank_accounts_on_branch_id_and_active"
    t.index ["branch_id"], name: "index_bank_accounts_on_branch_id"
    t.index ["business_id"], name: "index_bank_accounts_on_business_id"
  end

  create_table "biometric_devices", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_punch_timestamp"
    t.datetime "last_seen_at"
    t.string "location_note"
    t.string "name", null: false
    t.date "sync_from_date"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "name"], name: "index_biometric_devices_on_business_id_and_name", unique: true
    t.index ["business_id"], name: "index_biometric_devices_on_business_id"
    t.index ["last_punch_timestamp"], name: "index_biometric_devices_on_last_punch_timestamp"
    t.index ["token"], name: "index_biometric_devices_on_token", unique: true
  end

  create_table "biometric_punch_logs", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "attendance_record_id"
    t.bigint "biometric_device_id"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id"
    t.text "error_message"
    t.string "ip_address"
    t.datetime "punched_at", null: false
    t.text "raw_payload"
    t.datetime "received_at", null: false
    t.string "source", default: "biometric", null: false
    t.datetime "updated_at", null: false
    t.date "work_date"
    t.index ["action"], name: "index_biometric_punch_logs_on_action"
    t.index ["attendance_record_id"], name: "index_biometric_punch_logs_on_attendance_record_id"
    t.index ["biometric_device_id"], name: "index_biometric_punch_logs_on_biometric_device_id"
    t.index ["business_id"], name: "index_biometric_punch_logs_on_business_id"
    t.index ["employee_id", "punched_at"], name: "index_biometric_punch_logs_on_employee_id_and_punched_at"
    t.index ["employee_id"], name: "index_biometric_punch_logs_on_employee_id"
    t.index ["punched_at"], name: "index_biometric_punch_logs_on_punched_at"
    t.index ["received_at"], name: "index_biometric_punch_logs_on_received_at"
    t.index ["source"], name: "index_biometric_punch_logs_on_source"
  end

  create_table "branch_revenues", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, default: "0.0", null: false
    t.bigint "branch_id", null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.text "notes"
    t.date "period_month", null: false
    t.datetime "updated_at", null: false
    t.index ["branch_id", "period_month"], name: "index_branch_revenues_on_branch_id_and_period_month", unique: true
    t.index ["branch_id"], name: "index_branch_revenues_on_branch_id"
    t.index ["business_id"], name: "index_branch_revenues_on_business_id"
    t.index ["created_by_id"], name: "index_branch_revenues_on_created_by_id"
  end

  create_table "branches", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "address"
    t.integer "area_manager_id"
    t.integer "branch_manager_id"
    t.integer "business_id", null: false
    t.datetime "created_at", null: false
    t.boolean "geolocation_enabled", default: false, null: false
    t.decimal "latitude", precision: 10, scale: 8
    t.decimal "longitude", precision: 11, scale: 8
    t.string "name", null: false
    t.string "phone_number"
    t.integer "radius_meters", default: 100
    t.datetime "updated_at", null: false
    t.index ["area_manager_id"], name: "index_branches_on_area_manager_id"
    t.index ["branch_manager_id"], name: "index_branches_on_branch_manager_id"
    t.index ["business_id"], name: "index_branches_on_business_id"
  end

  create_table "brands", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index "business_id, lower((name)::text)", name: "index_brands_on_business_id_and_lower_name", unique: true
    t.index ["business_id"], name: "index_brands_on_business_id"
  end

  create_table "business_closing_locks", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "locked_by_id", null: false
    t.date "locked_through_date", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.index ["business_id", "locked_through_date"], name: "index_closing_locks_on_business_and_date"
    t.index ["business_id"], name: "index_business_closing_locks_on_business_id"
    t.index ["locked_by_id"], name: "index_business_closing_locks_on_locked_by_id"
  end

  create_table "businesses", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "barcode_next_number", default: 1, null: false
    t.string "barcode_prefix"
    t.integer "business_day_start_hour", default: 6, null: false
    t.decimal "closing_variance_threshold", precision: 8, scale: 2, default: "10.0", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "SAR", null: false
    t.string "default_locale", default: "en", null: false
    t.integer "employee_code_start", default: 1, null: false, comment: "starting number for auto-generated employee_code"
    t.integer "max_early_leave_permission_minutes"
    t.integer "max_late_permission_minutes"
    t.decimal "max_salary_advance_percentage", precision: 5, scale: 2
    t.string "name", null: false
    t.integer "overtime_grace_minutes", default: 0, null: false
    t.bigint "owner_id"
    t.integer "payroll_auto_generate_day", comment: "day-of-month to auto-generate (nil = disabled, 1-28)"
    t.integer "payroll_cutoff_day", default: 0, null: false, comment: "attendance cutoff day for prior month (0 = end-of-month)"
    t.text "settings"
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.boolean "variant_system_enabled", default: true, null: false
    t.integer "working_days_per_month", default: 26, null: false
    t.index ["owner_id"], name: "index_businesses_on_owner_id"
  end

  create_table "cash_deposits", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.bigint "bank_account_id"
    t.datetime "created_at", null: false
    t.bigint "daily_closing_id", null: false
    t.bigint "deposited_by_id", null: false
    t.date "deposited_on", null: false
    t.text "notes"
    t.string "reference_number"
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.index ["bank_account_id", "deposited_on"], name: "index_cash_deposits_on_bank_account_id_and_deposited_on"
    t.index ["bank_account_id"], name: "index_cash_deposits_on_bank_account_id"
    t.index ["daily_closing_id", "deposited_on"], name: "index_cash_deposits_on_daily_closing_id_and_deposited_on"
    t.index ["daily_closing_id"], name: "index_cash_deposits_on_daily_closing_id"
    t.index ["deposited_by_id"], name: "index_cash_deposits_on_deposited_by_id"
    t.index ["voided_at"], name: "index_cash_deposits_on_voided_at"
    t.index ["voided_by_id"], name: "index_cash_deposits_on_voided_by_id"
  end

  create_table "cash_handovers", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.bigint "daily_closing_id"
    t.bigint "from_staff_closing_id", null: false
    t.bigint "from_user_id", null: false
    t.text "notes"
    t.datetime "responded_at"
    t.bigint "responded_by_id"
    t.text "response_notes"
    t.string "status", default: "pending", null: false
    t.bigint "to_user_id", null: false
    t.datetime "transferred_at", null: false
    t.datetime "updated_at", null: false
    t.index ["daily_closing_id"], name: "idx_cash_handovers_daily_closing"
    t.index ["daily_closing_id"], name: "index_cash_handovers_on_daily_closing_id"
    t.index ["from_staff_closing_id"], name: "idx_cash_handovers_from_staff_closing"
    t.index ["from_staff_closing_id"], name: "index_cash_handovers_on_from_staff_closing_id"
    t.index ["from_user_id", "status"], name: "idx_cash_handovers_from_user_status"
    t.index ["from_user_id"], name: "idx_cash_handovers_from_user"
    t.index ["from_user_id"], name: "index_cash_handovers_on_from_user_id"
    t.index ["to_user_id", "status"], name: "idx_cash_handovers_to_user_status"
    t.index ["to_user_id"], name: "idx_cash_handovers_to_user"
    t.index ["to_user_id"], name: "index_cash_handovers_on_to_user_id"
  end

  create_table "custody_accounts", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "branch_id"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.decimal "current_balance", precision: 12, scale: 2, default: "0.0", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["branch_id"], name: "index_custody_accounts_on_branch_id"
    t.index ["business_id", "user_id"], name: "index_custody_accounts_on_business_id_and_user_id", unique: true
    t.index ["business_id"], name: "index_custody_accounts_on_business_id"
    t.index ["user_id"], name: "index_custody_accounts_on_user_id"
  end

  create_table "custody_transactions", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.bigint "custody_account_id", null: false
    t.bigint "expense_id"
    t.text "notes"
    t.bigint "transfer_counterparty_id"
    t.string "txn_type", null: false
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.index ["approved_by_id"], name: "index_custody_transactions_on_approved_by_id"
    t.index ["business_id", "txn_type"], name: "index_custody_transactions_on_business_id_and_txn_type"
    t.index ["business_id"], name: "index_custody_transactions_on_business_id"
    t.index ["created_by_id"], name: "index_custody_transactions_on_created_by_id"
    t.index ["custody_account_id"], name: "index_custody_transactions_on_custody_account_id"
    t.index ["expense_id"], name: "index_custody_transactions_on_expense_id"
    t.index ["transfer_counterparty_id"], name: "index_custody_transactions_on_transfer_counterparty_id"
    t.index ["voided_by_id"], name: "index_custody_transactions_on_voided_by_id"
  end

  create_table "daily_closing_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "daily_closing_id", null: false
    t.text "notes"
    t.bigint "payment_method_id", null: false
    t.decimal "refunds_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "sales_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["daily_closing_id", "payment_method_id"], name: "idx_closing_entries_on_closing_and_method", unique: true
    t.index ["daily_closing_id"], name: "index_daily_closing_entries_on_daily_closing_id"
    t.index ["payment_method_id"], name: "index_daily_closing_entries_on_payment_method_id"
  end

  create_table "daily_closings", force: :cascade do |t|
    t.bigint "branch_id", null: false
    t.bigint "business_id", null: false
    t.date "closing_date", null: false
    t.datetime "created_at", null: false
    t.text "investigation_notes"
    t.integer "lock_version", default: 0, null: false
    t.text "notes"
    t.string "status", default: "draft", null: false
    t.datetime "submitted_at"
    t.bigint "submitted_by_id"
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.bigint "verified_by_id"
    t.index ["branch_id", "closing_date"], name: "index_daily_closings_on_branch_id_and_closing_date", unique: true
    t.index ["branch_id"], name: "index_daily_closings_on_branch_id"
    t.index ["business_id", "closing_date"], name: "index_daily_closings_on_business_id_and_closing_date"
    t.index ["business_id", "status"], name: "index_daily_closings_on_business_id_and_status"
    t.index ["business_id"], name: "index_daily_closings_on_business_id"
    t.index ["submitted_by_id"], name: "index_daily_closings_on_submitted_by_id"
    t.index ["verified_by_id"], name: "index_daily_closings_on_verified_by_id"
  end

  create_table "departments", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index "business_id, lower((name)::text)", name: "index_departments_on_business_id_and_lower_name", unique: true
    t.index ["business_id"], name: "index_departments_on_business_id"
  end

  create_table "employee_obligations", force: :cascade do |t|
    t.boolean "auto_deduct", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.text "description"
    t.integer "end_month"
    t.integer "end_year"
    t.decimal "installment_amount", precision: 12, scale: 2, null: false
    t.integer "installments_count", default: 1, null: false
    t.text "notes"
    t.string "obligation_type", null: false
    t.decimal "remaining_amount", precision: 12, scale: 2, null: false
    t.integer "start_month", null: false
    t.integer "start_year", null: false
    t.string "status", default: "active", null: false
    t.string "title", null: false
    t.decimal "total_amount", precision: 12, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["business_id", "status"], name: "index_employee_obligations_on_business_id_and_status"
    t.index ["business_id"], name: "index_employee_obligations_on_business_id"
    t.index ["created_by_id"], name: "index_employee_obligations_on_created_by_id"
    t.index ["user_id", "status"], name: "index_employee_obligations_on_user_id_and_status"
    t.index ["user_id"], name: "index_employee_obligations_on_user_id"
  end

  create_table "employee_requests", force: :cascade do |t|
    t.boolean "affects_payroll", default: false, null: false
    t.decimal "amount", precision: 12, scale: 2
    t.string "approved_time"
    t.text "cancellation_reason"
    t.datetime "cancelled_at"
    t.bigint "cancelled_by_id"
    t.string "correction_type"
    t.datetime "created_at", null: false
    t.integer "duration_minutes"
    t.datetime "original_check_in_at"
    t.string "original_check_in_source"
    t.datetime "original_check_out_at"
    t.string "original_check_out_source"
    t.date "proposed_date"
    t.string "proposed_time"
    t.text "reason", null: false
    t.string "request_type", null: false
    t.date "requested_for_date", null: false
    t.text "response_note"
    t.datetime "reviewed_at"
    t.integer "reviewed_by_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["cancelled_by_id"], name: "index_employee_requests_on_cancelled_by_id"
    t.index ["reviewed_by_id"], name: "index_employee_requests_on_reviewed_by_id"
    t.index ["user_id", "request_type", "requested_for_date"], name: "idx_on_user_id_request_type_requested_for_date_bed206bfdf"
    t.index ["user_id"], name: "index_employee_requests_on_user_id"
  end

  create_table "evaluation_criteria", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "evaluation_template_id", null: false
    t.string "name", null: false
    t.integer "sort_order", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["evaluation_template_id", "sort_order"], name: "idx_on_evaluation_template_id_sort_order_1f1b8b8ce2"
    t.index ["evaluation_template_id"], name: "index_evaluation_criteria_on_evaluation_template_id"
  end

  create_table "evaluation_templates", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "department_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id"], name: "index_evaluation_templates_on_business_id"
    t.index ["department_id", "active"], name: "index_evaluation_templates_on_department_id_and_active"
    t.index ["department_id"], name: "index_evaluation_templates_on_department_id"
  end

  create_table "expense_allocations", force: :cascade do |t|
    t.decimal "allocated_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "allocation_percentage", precision: 5, scale: 2, default: "0.0", null: false
    t.bigint "branch_id", null: false
    t.datetime "created_at", null: false
    t.bigint "expense_id", null: false
    t.datetime "updated_at", null: false
    t.index ["branch_id"], name: "index_expense_allocations_on_branch_id"
    t.index ["expense_id", "branch_id"], name: "index_expense_allocations_on_expense_id_and_branch_id", unique: true
    t.index ["expense_id"], name: "index_expense_allocations_on_expense_id"
  end

  create_table "expense_categories", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index "business_id, lower((name)::text)", name: "index_expense_categories_on_business_id_and_lower_name", unique: true
    t.index ["business_id"], name: "index_expense_categories_on_business_id"
  end

  create_table "expense_taggings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "expense_id", null: false
    t.bigint "expense_tag_id", null: false
    t.datetime "updated_at", null: false
    t.index ["expense_id", "expense_tag_id"], name: "index_expense_taggings_on_expense_id_and_expense_tag_id", unique: true
    t.index ["expense_id"], name: "index_expense_taggings_on_expense_id"
    t.index ["expense_tag_id"], name: "index_expense_taggings_on_expense_tag_id"
  end

  create_table "expense_tags", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index "business_id, lower((name)::text)", name: "index_expense_tags_on_business_id_and_lower_name", unique: true
    t.index ["business_id"], name: "index_expense_tags_on_business_id"
  end

  create_table "expense_types", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "expense_category_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index "expense_category_id, lower((name)::text)", name: "index_expense_types_on_category_id_and_lower_name", unique: true
    t.index ["business_id"], name: "index_expense_types_on_business_id"
    t.index ["expense_category_id"], name: "index_expense_types_on_expense_category_id"
  end

  create_table "expenses", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.bigint "branch_id"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.boolean "deduct_from_balance", default: true, null: false
    t.text "description"
    t.bigint "expense_category_id", null: false
    t.date "expense_date", null: false
    t.bigint "expense_type_id"
    t.boolean "is_shared", default: false, null: false
    t.text "notes"
    t.string "reference_number", null: false
    t.datetime "rejected_at"
    t.text "rejection_reason"
    t.bigint "source_recurring_expense_id"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_expenses_on_approved_by_id"
    t.index ["branch_id", "expense_date"], name: "index_expenses_on_branch_id_and_expense_date"
    t.index ["business_id", "expense_date"], name: "index_expenses_on_business_id_and_expense_date"
    t.index ["business_id", "reference_number"], name: "index_expenses_on_business_id_and_reference_number", unique: true
    t.index ["business_id", "status"], name: "index_expenses_on_business_id_and_status"
    t.index ["business_id"], name: "index_expenses_on_business_id"
    t.index ["created_by_id"], name: "index_expenses_on_created_by_id"
    t.index ["expense_category_id"], name: "index_expenses_on_expense_category_id"
    t.index ["expense_type_id"], name: "index_expenses_on_expense_type_id"
    t.index ["source_recurring_expense_id", "expense_date"], name: "index_expenses_on_recurring_source_and_date", unique: true, where: "(source_recurring_expense_id IS NOT NULL)"
    t.index ["source_recurring_expense_id"], name: "index_expenses_on_source_recurring_expense_id"
  end

  create_table "external_sales_imports", force: :cascade do |t|
    t.bigint "branch_id", null: false
    t.bigint "business_id", null: false
    t.datetime "confirmed_at"
    t.bigint "confirmed_by_id"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.bigint "daily_closing_id"
    t.integer "error_count", default: 0
    t.integer "mapped_count", default: 0
    t.string "original_filename"
    t.text "parse_errors"
    t.integer "row_count", default: 0
    t.date "sales_date", null: false
    t.integer "skipped_count", default: 0
    t.string "source", null: false
    t.decimal "source_gross", precision: 14, scale: 2
    t.decimal "source_net", precision: 14, scale: 2
    t.decimal "source_refunds", precision: 14, scale: 2
    t.string "source_version"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "uploaded_by_id", null: false
    t.index ["branch_id", "status"], name: "index_external_sales_imports_on_branch_id_and_status"
    t.index ["branch_id"], name: "index_external_sales_imports_on_branch_id"
    t.index ["business_id", "sales_date"], name: "index_external_sales_imports_on_business_id_and_sales_date"
    t.index ["business_id"], name: "index_external_sales_imports_on_business_id"
    t.index ["confirmed_by_id"], name: "index_external_sales_imports_on_confirmed_by_id"
    t.index ["daily_closing_id"], name: "idx_ext_sales_imports_on_daily_closing"
    t.index ["daily_closing_id"], name: "index_external_sales_imports_on_daily_closing_id"
    t.index ["uploaded_by_id"], name: "index_external_sales_imports_on_uploaded_by_id"
  end

  create_table "external_sales_rows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "external_sales_import_id", null: false
    t.decimal "gross_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "net_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.text "notes"
    t.bigint "payment_method_id"
    t.text "raw_data"
    t.decimal "refund_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.string "row_status", default: "mapped", null: false
    t.string "source_payment_method"
    t.integer "source_row_number"
    t.datetime "updated_at", null: false
    t.index ["external_sales_import_id", "payment_method_id"], name: "idx_on_external_sales_import_id_payment_method_id_f467af8bd8"
    t.index ["external_sales_import_id", "row_status"], name: "idx_on_external_sales_import_id_row_status_608612d9ec"
    t.index ["external_sales_import_id"], name: "index_external_sales_rows_on_external_sales_import_id"
    t.index ["payment_method_id"], name: "index_external_sales_rows_on_payment_method_id"
  end

  create_table "goods_receipt_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "goods_receipt_id", null: false
    t.bigint "product_id", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.decimal "total_cost", precision: 14, scale: 4, default: "0.0", null: false
    t.decimal "unit_cost", precision: 12, scale: 4, null: false
    t.datetime "updated_at", null: false
    t.index ["goods_receipt_id"], name: "index_goods_receipt_items_on_goods_receipt_id"
    t.index ["product_id"], name: "index_goods_receipt_items_on_product_id"
  end

  create_table "goods_receipts", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.text "notes"
    t.string "receipt_number", null: false
    t.date "received_on", null: false
    t.bigint "supplier_id"
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.bigint "warehouse_id", null: false
    t.index ["business_id", "receipt_number"], name: "index_goods_receipts_on_business_id_and_receipt_number", unique: true
    t.index ["business_id"], name: "index_goods_receipts_on_business_id"
    t.index ["created_by_id"], name: "index_goods_receipts_on_created_by_id"
    t.index ["supplier_id"], name: "index_goods_receipts_on_supplier_id"
    t.index ["voided_by_id"], name: "index_goods_receipts_on_voided_by_id"
    t.index ["warehouse_id"], name: "index_goods_receipts_on_warehouse_id"
  end

  create_table "inventory_movements", force: :cascade do |t|
    t.bigint "branch_id"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.string "direction", null: false
    t.date "occurred_on", null: false
    t.bigint "product_id", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.string "reason", null: false
    t.bigint "source_id"
    t.string "source_type"
    t.decimal "unit_cost", precision: 12, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.bigint "warehouse_id", null: false
    t.index ["branch_id", "occurred_on"], name: "index_inventory_movements_on_branch_id_and_occurred_on"
    t.index ["business_id", "occurred_on"], name: "index_inventory_movements_on_business_id_and_occurred_on"
    t.index ["business_id"], name: "index_inventory_movements_on_business_id"
    t.index ["product_id", "warehouse_id"], name: "index_inventory_movements_on_product_id_and_warehouse_id"
    t.index ["product_id"], name: "index_inventory_movements_on_product_id"
    t.index ["source_type", "source_id"], name: "index_inventory_movements_on_source"
    t.index ["warehouse_id"], name: "index_inventory_movements_on_warehouse_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.text "body"
    t.string "category"
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.string "event_type", null: false
    t.bigint "notifiable_id"
    t.string "notifiable_type"
    t.datetime "read_at"
    t.string "severity", default: "info", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["event_type"], name: "index_notifications_on_event_type"
    t.index ["notifiable_type", "notifiable_id"], name: "index_notifications_on_notifiable"
    t.index ["user_id", "category"], name: "index_notifications_on_user_id_and_category"
    t.index ["user_id", "created_at"], name: "index_notifications_on_user_id_and_created_at"
    t.index ["user_id", "read_at"], name: "index_notifications_on_user_id_and_read_at"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "obligation_deductions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "deducted_amount", precision: 12, scale: 2, null: false
    t.bigint "employee_obligation_id", null: false
    t.bigint "payroll_period_id", null: false
    t.decimal "remaining_after", precision: 12, scale: 2, null: false
    t.decimal "remaining_before", precision: 12, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.index ["employee_obligation_id", "payroll_period_id"], name: "idx_obligation_deductions_unique", unique: true
    t.index ["employee_obligation_id"], name: "index_obligation_deductions_on_employee_obligation_id"
    t.index ["payroll_period_id"], name: "index_obligation_deductions_on_payroll_period_id"
  end

  create_table "payment_methods", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "name_ar"
    t.integer "position", default: 0, null: false
    t.string "settlement_type", default: "other", null: false
    t.boolean "supports_refunds", default: true, null: false
    t.datetime "updated_at", null: false
    t.index "business_id, lower((name)::text)", name: "index_payment_methods_on_business_id_and_lower_name", unique: true
    t.index ["business_id", "active", "position"], name: "index_payment_methods_on_business_id_and_active_and_position"
    t.index ["business_id", "settlement_type"], name: "index_payment_methods_on_business_id_and_settlement_type"
    t.index ["business_id"], name: "index_payment_methods_on_business_id"
  end

  create_table "payroll_adjustments", force: :cascade do |t|
    t.string "adjustment_type", null: false
    t.boolean "already_paid", default: false, null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "approved_at"
    t.integer "approved_by_id"
    t.string "bulk_batch_id"
    t.integer "business_id", null: false
    t.datetime "created_at", null: false
    t.integer "created_by_id", null: false
    t.string "import_source", default: "manual", null: false
    t.datetime "paid_at"
    t.string "payment_method"
    t.integer "payroll_period_id"
    t.integer "period_month", null: false
    t.integer "period_year", null: false
    t.string "reason", null: false
    t.datetime "rejected_at"
    t.integer "rejected_by_id"
    t.text "review_notes"
    t.string "review_status", default: "pending_review", null: false
    t.datetime "reviewed_at"
    t.integer "reviewed_by_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["approved_by_id"], name: "index_payroll_adjustments_on_approved_by_id"
    t.index ["bulk_batch_id"], name: "index_payroll_adjustments_on_bulk_batch_id"
    t.index ["business_id", "period_year", "period_month", "user_id"], name: "index_payroll_adjustments_on_period_and_user"
    t.index ["business_id"], name: "index_payroll_adjustments_on_business_id"
    t.index ["created_by_id"], name: "index_payroll_adjustments_on_created_by_id"
    t.index ["payroll_period_id", "review_status"], name: "idx_payroll_adj_period_status"
    t.index ["payroll_period_id", "user_id"], name: "index_payroll_adjustments_on_payroll_period_id_and_user_id"
    t.index ["payroll_period_id"], name: "index_payroll_adjustments_on_payroll_period_id"
    t.index ["rejected_by_id"], name: "index_payroll_adjustments_on_rejected_by_id"
    t.index ["reviewed_by_id"], name: "index_payroll_adjustments_on_reviewed_by_id"
    t.index ["user_id"], name: "index_payroll_adjustments_on_user_id"
  end

  create_table "payroll_audit_logs", force: :cascade do |t|
    t.string "action_type", null: false
    t.integer "actor_id", null: false
    t.datetime "created_at", null: false
    t.string "from_status"
    t.text "metadata"
    t.integer "payroll_period_id"
    t.string "to_status"
    t.datetime "updated_at", null: false
    t.index ["action_type"], name: "index_payroll_audit_logs_on_action_type"
    t.index ["actor_id"], name: "index_payroll_audit_logs_on_actor_id"
    t.index ["payroll_period_id"], name: "index_payroll_audit_logs_on_payroll_period_id"
  end

  create_table "payroll_entries", force: :cascade do |t|
    t.decimal "advances_deducted", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "already_paid_total", precision: 12, scale: 2, default: "0.0", null: false
    t.integer "approved_overtime_minutes"
    t.decimal "approved_overtime_pay", precision: 12, scale: 2
    t.decimal "base_salary", precision: 12, scale: 2, null: false
    t.integer "calculated_overtime_minutes", default: 0, null: false
    t.decimal "calculated_overtime_pay", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.integer "days_worked", default: 0, null: false
    t.decimal "net_salary", precision: 12, scale: 2, null: false
    t.text "notes"
    t.decimal "obligations_deducted", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "overtime_overridden_at"
    t.integer "overtime_overridden_by_id"
    t.string "overtime_override_mode"
    t.string "overtime_override_reason"
    t.boolean "overtime_override_stale", default: false, null: false
    t.integer "payroll_period_id", null: false
    t.string "salary_type", null: false
    t.string "status", default: "draft", null: false
    t.decimal "total_bonuses", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total_deductions", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total_overtime", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "working_days", null: false
    t.index ["overtime_overridden_by_id"], name: "index_payroll_entries_on_overtime_overridden_by_id"
    t.index ["payroll_period_id", "user_id"], name: "index_payroll_entries_on_payroll_period_id_and_user_id", unique: true
    t.index ["payroll_period_id"], name: "index_payroll_entries_on_payroll_period_id"
    t.index ["user_id", "status"], name: "index_payroll_entries_on_user_id_and_status"
    t.index ["user_id"], name: "index_payroll_entries_on_user_id"
  end

  create_table "payroll_line_items", force: :cascade do |t|
    t.boolean "already_paid", default: false, null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.boolean "deduction_waived", default: false, null: false
    t.datetime "deduction_waived_at"
    t.integer "deduction_waived_by_id"
    t.string "deduction_waiver_reason"
    t.string "description"
    t.string "item_type", null: false
    t.integer "original_minutes"
    t.integer "payroll_entry_id", null: false
    t.integer "permission_minutes"
    t.text "review_notes"
    t.string "review_status", default: "approved", null: false
    t.datetime "reviewed_at"
    t.integer "reviewed_by_id"
    t.bigint "source_id"
    t.string "source_type"
    t.datetime "updated_at", null: false
    t.index ["deduction_waived_by_id"], name: "index_payroll_line_items_on_deduction_waived_by_id"
    t.index ["payroll_entry_id", "deduction_waived"], name: "idx_payroll_line_items_entry_waived"
    t.index ["payroll_entry_id", "review_status"], name: "idx_payroll_line_items_entry_status"
    t.index ["payroll_entry_id"], name: "index_payroll_line_items_on_payroll_entry_id"
    t.index ["review_status"], name: "index_payroll_line_items_on_review_status"
    t.index ["reviewed_by_id"], name: "index_payroll_line_items_on_reviewed_by_id"
    t.index ["source_type", "source_id"], name: "index_payroll_line_items_on_source_type_and_source_id"
  end

  create_table "payroll_period_branch_reviews", force: :cascade do |t|
    t.integer "branch_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "notes"
    t.integer "payroll_period_id", null: false
    t.integer "reviewer_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["branch_id"], name: "index_payroll_period_branch_reviews_on_branch_id"
    t.index ["payroll_period_id", "branch_id"], name: "index_payroll_period_branch_reviews_unique", unique: true
    t.index ["payroll_period_id"], name: "index_payroll_period_branch_reviews_on_payroll_period_id"
    t.index ["reviewer_id"], name: "index_payroll_period_branch_reviews_on_reviewer_id"
  end

  create_table "payroll_periods", force: :cascade do |t|
    t.integer "branch_id"
    t.integer "business_id", null: false
    t.datetime "created_at", null: false
    t.datetime "finalized_at"
    t.integer "finalized_by_id"
    t.datetime "generated_at"
    t.integer "generated_by_id"
    t.integer "period_month", null: false
    t.integer "period_year", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.integer "working_days", null: false
    t.index ["branch_id"], name: "index_payroll_periods_on_branch_id"
    t.index ["business_id", "period_year", "period_month"], name: "idx_payroll_periods_business_ym", unique: true
    t.index ["business_id", "period_year", "period_month"], name: "index_payroll_periods_unique", unique: true
    t.index ["business_id"], name: "index_payroll_periods_on_business_id"
    t.index ["finalized_by_id"], name: "index_payroll_periods_on_finalized_by_id"
    t.index ["generated_by_id"], name: "index_payroll_periods_on_generated_by_id"
  end

  create_table "payroll_snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "employee_count", default: 0, null: false
    t.jsonb "employee_details", default: {}, null: false
    t.bigint "payroll_period_id", null: false
    t.bigint "taken_by_id", null: false
    t.decimal "total_base", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total_bonuses", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total_deductions", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total_net", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total_overtime", precision: 12, scale: 2, default: "0.0", null: false
    t.string "trigger", default: "pre_regenerate", null: false
    t.datetime "updated_at", null: false
    t.index ["payroll_period_id", "created_at"], name: "index_payroll_snapshots_on_payroll_period_id_and_created_at"
    t.index ["payroll_period_id"], name: "index_payroll_snapshots_on_payroll_period_id"
    t.index ["taken_by_id"], name: "index_payroll_snapshots_on_taken_by_id"
  end

  create_table "penalty_rules", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "deduction_type", null: false
    t.decimal "deduction_value", precision: 10, scale: 2, null: false
    t.string "rule_type", null: false
    t.integer "shift_id", null: false
    t.integer "threshold_minutes", null: false
    t.datetime "updated_at", null: false
    t.index ["shift_id", "rule_type", "threshold_minutes"], name: "index_penalty_rules_on_shift_type_threshold", unique: true
    t.index ["shift_id"], name: "index_penalty_rules_on_shift_id"
  end

  create_table "performance_observations", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "employee_id", null: false
    t.bigint "evaluation_criterion_id", null: false
    t.text "note"
    t.date "observation_date", null: false
    t.string "observation_type", null: false
    t.bigint "observed_by_id", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "observation_type", "evaluation_criterion_id"], name: "index_observations_on_business_type_criterion"
    t.index ["business_id"], name: "index_performance_observations_on_business_id"
    t.index ["employee_id", "observation_date"], name: "idx_on_employee_id_observation_date_7defa356e1"
    t.index ["employee_id"], name: "index_performance_observations_on_employee_id"
    t.index ["evaluation_criterion_id"], name: "index_performance_observations_on_evaluation_criterion_id"
    t.index ["observed_by_id"], name: "index_performance_observations_on_observed_by_id"
  end

  create_table "performance_review_scores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "evaluation_criterion_id", null: false
    t.bigint "performance_review_id", null: false
    t.integer "score", null: false
    t.datetime "updated_at", null: false
    t.index ["evaluation_criterion_id"], name: "index_performance_review_scores_on_evaluation_criterion_id"
    t.index ["performance_review_id", "evaluation_criterion_id"], name: "index_review_scores_on_review_and_criterion", unique: true
    t.index ["performance_review_id"], name: "index_performance_review_scores_on_performance_review_id"
  end

  create_table "performance_reviews", force: :cascade do |t|
    t.decimal "average_score", precision: 4, scale: 2
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "department_id", null: false
    t.bigint "employee_id", null: false
    t.datetime "finalized_at"
    t.text "notes"
    t.integer "review_month", null: false
    t.string "review_period"
    t.integer "review_year", null: false
    t.bigint "reviewer_id", null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "review_year", "review_month"], name: "idx_on_business_id_review_year_review_month_fad3bf3d11"
    t.index ["business_id", "status"], name: "index_performance_reviews_on_business_id_and_status"
    t.index ["business_id"], name: "index_performance_reviews_on_business_id"
    t.index ["department_id", "review_year", "review_month"], name: "idx_on_department_id_review_year_review_month_4e53278bd0"
    t.index ["department_id"], name: "index_performance_reviews_on_department_id"
    t.index ["employee_id", "review_year", "review_month"], name: "idx_on_employee_id_review_year_review_month_7c271668da"
    t.index ["employee_id"], name: "index_performance_reviews_on_employee_id"
    t.index ["reviewer_id"], name: "index_performance_reviews_on_reviewer_id"
  end

  create_table "permission_roles", force: :cascade do |t|
    t.integer "business_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.jsonb "permission_scopes", default: {}, null: false
    t.jsonb "permissions", default: [], null: false
    t.string "role_type"
    t.datetime "updated_at", null: false
    t.index ["business_id", "name"], name: "index_permission_roles_on_business_id_and_name", unique: true
    t.index ["business_id"], name: "index_permission_roles_on_business_id"
  end

  create_table "pos_terminals", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "branch_id", null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.string "name"
    t.text "notes"
    t.string "provider"
    t.string "terminal_id", null: false
    t.datetime "updated_at", null: false
    t.index "business_id, lower((terminal_id)::text)", name: "index_pos_terminals_on_business_id_and_lower_terminal_id", unique: true
    t.index ["branch_id", "active"], name: "index_pos_terminals_on_branch_id_and_active"
    t.index ["branch_id"], name: "index_pos_terminals_on_branch_id"
    t.index ["business_id"], name: "index_pos_terminals_on_business_id"
  end

  create_table "product_barcodes", force: :cascade do |t|
    t.string "barcode", null: false
    t.string "barcode_type", null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.boolean "is_primary", default: false, null: false
    t.bigint "product_id", null: false
    t.bigint "variant_id"
    t.index "business_id, lower((barcode)::text)", name: "index_product_barcodes_on_business_id_lower_barcode", unique: true
    t.index ["product_id"], name: "index_product_barcodes_on_product_id"
  end

  create_table "product_categories", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index "business_id, lower((name)::text)", name: "index_product_categories_on_business_id_and_lower_name", unique: true
    t.index ["business_id"], name: "index_product_categories_on_business_id"
  end

  create_table "product_variants", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.bigint "product_id", null: false
    t.string "sku"
    t.datetime "updated_at", null: false
    t.index ["product_id", "position"], name: "index_product_variants_on_product_id_and_position"
    t.index ["product_id"], name: "index_product_variants_on_product_id"
  end

  create_table "product_warehouse_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "low_stock_level", precision: 12, scale: 3, default: "0.0", null: false
    t.bigint "product_id", null: false
    t.decimal "reorder_quantity", precision: 12, scale: 3, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.bigint "warehouse_id", null: false
    t.index ["product_id", "warehouse_id"], name: "idx_on_product_id_warehouse_id_c543ed27c8", unique: true
    t.index ["product_id"], name: "index_product_warehouse_settings_on_product_id"
    t.index ["warehouse_id"], name: "index_product_warehouse_settings_on_warehouse_id"
  end

  create_table "products", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.decimal "average_cost_price", precision: 12, scale: 4, default: "0.0", null: false
    t.string "barcode"
    t.bigint "brand_id"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "default_supplier_id"
    t.decimal "initial_cost_price", precision: 12, scale: 4, default: "0.0", null: false
    t.decimal "last_purchase_price", precision: 12, scale: 4
    t.decimal "low_stock_level", precision: 12, scale: 3, default: "0.0", null: false
    t.string "name", null: false
    t.text "notes"
    t.bigint "parent_product_id"
    t.bigint "product_category_id"
    t.boolean "receive_low_stock_notification", default: true, null: false
    t.integer "reorder_level", default: 0, null: false
    t.decimal "reorder_quantity", precision: 12, scale: 3, default: "0.0", null: false
    t.decimal "selling_markup_percentage", precision: 8, scale: 2, default: "0.0", null: false
    t.string "sku", null: false
    t.boolean "track_inventory", default: true, null: false
    t.datetime "updated_at", null: false
    t.index "business_id, lower((barcode)::text)", name: "index_products_on_business_id_and_lower_barcode", unique: true, where: "((barcode IS NOT NULL) AND ((barcode)::text <> ''::text))"
    t.index "business_id, lower((sku)::text)", name: "index_products_on_business_id_and_lower_sku", unique: true
    t.index ["brand_id"], name: "index_products_on_brand_id"
    t.index ["business_id", "active"], name: "index_products_on_business_id_and_active"
    t.index ["business_id", "parent_product_id"], name: "index_products_on_business_id_and_parent_product_id"
    t.index ["business_id"], name: "index_products_on_business_id"
    t.index ["default_supplier_id"], name: "index_products_on_default_supplier_id"
    t.index ["parent_product_id"], name: "index_products_on_parent_product_id"
    t.index ["product_category_id"], name: "index_products_on_product_category_id"
  end

  create_table "recurring_expense_allocations", force: :cascade do |t|
    t.decimal "allocation_percentage", precision: 5, scale: 2, default: "0.0", null: false
    t.bigint "branch_id", null: false
    t.datetime "created_at", null: false
    t.bigint "recurring_expense_id", null: false
    t.datetime "updated_at", null: false
    t.index ["branch_id"], name: "index_recurring_expense_allocations_on_branch_id"
    t.index ["recurring_expense_id", "branch_id"], name: "index_recurring_allocations_on_recurring_and_branch", unique: true
    t.index ["recurring_expense_id"], name: "index_recurring_expense_allocations_on_recurring_expense_id"
  end

  create_table "recurring_expenses", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.bigint "branch_id"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.date "end_date"
    t.bigint "expense_category_id", null: false
    t.bigint "expense_type_id"
    t.string "frequency", null: false
    t.date "last_generated_on"
    t.date "next_run_on", null: false
    t.date "start_date", null: false
    t.datetime "updated_at", null: false
    t.index ["branch_id"], name: "index_recurring_expenses_on_branch_id"
    t.index ["business_id", "active", "next_run_on"], name: "idx_on_business_id_active_next_run_on_34340a316c"
    t.index ["business_id"], name: "index_recurring_expenses_on_business_id"
    t.index ["created_by_id"], name: "index_recurring_expenses_on_created_by_id"
    t.index ["expense_category_id"], name: "index_recurring_expenses_on_expense_category_id"
    t.index ["expense_type_id"], name: "index_recurring_expenses_on_expense_type_id"
  end

  create_table "reopen_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "daily_closing_id", null: false
    t.text "reason", null: false
    t.bigint "requested_by_id", null: false
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.text "reviewer_notes"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["daily_closing_id", "status"], name: "index_reopen_requests_on_daily_closing_id_and_status"
    t.index ["daily_closing_id"], name: "index_reopen_requests_on_daily_closing_id"
    t.index ["requested_by_id"], name: "index_reopen_requests_on_requested_by_id"
    t.index ["reviewed_by_id"], name: "index_reopen_requests_on_reviewed_by_id"
  end

  create_table "salary_profiles", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.decimal "base_amount", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "SAR", null: false
    t.date "effective_from", null: false
    t.decimal "overtime_multiplier", precision: 4, scale: 2
    t.string "salary_type", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "active"], name: "index_salary_profiles_on_user_id_and_active"
    t.index ["user_id"], name: "index_salary_profiles_on_user_id"
  end

  create_table "sales_mapping_profiles", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.text "column_map"
    t.datetime "created_at", null: false
    t.boolean "default", default: false, null: false
    t.text "method_map"
    t.string "name", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "source"], name: "idx_mapping_profiles_on_business_and_source", unique: true
    t.index ["business_id"], name: "index_sales_mapping_profiles_on_business_id"
  end

  create_table "shift_assignments", force: :cascade do |t|
    t.integer "branch_id"
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.date "effective_from", null: false
    t.date "effective_to"
    t.bigint "ended_by_id"
    t.integer "shift_id", null: false
    t.bigint "shift_rule_profile_id"
    t.bigint "source_template_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["branch_id"], name: "index_shift_assignments_on_branch_id"
    t.index ["created_by_id"], name: "index_shift_assignments_on_created_by_id"
    t.index ["ended_by_id"], name: "index_shift_assignments_on_ended_by_id"
    t.index ["shift_id"], name: "index_shift_assignments_on_shift_id"
    t.index ["shift_rule_profile_id"], name: "index_shift_assignments_on_shift_rule_profile_id"
    t.index ["source_template_id"], name: "index_shift_assignments_on_source_template_id"
    t.index ["user_id", "branch_id"], name: "index_shift_assignments_on_user_id_and_branch_id"
    t.index ["user_id", "effective_from"], name: "index_shift_assignments_on_user_id_and_effective_from"
    t.index ["user_id"], name: "index_shift_assignments_on_user_id"
  end

  create_table "shift_rule_profiles", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "break_minutes"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "early_leave_grace_minutes"
    t.decimal "expected_work_hours", precision: 5, scale: 2
    t.integer "late_grace_minutes"
    t.string "name", null: false
    t.boolean "overtime_enabled", default: true, null: false
    t.decimal "overtime_multiplier", precision: 5, scale: 2
    t.datetime "updated_at", null: false
    t.index ["business_id", "name"], name: "index_shift_rule_profiles_on_business_id_and_name", unique: true
    t.index ["business_id"], name: "index_shift_rule_profiles_on_business_id"
  end

  create_table "shift_template_entries", force: :cascade do |t|
    t.bigint "branch_id"
    t.datetime "created_at", null: false
    t.integer "effective_from_offset"
    t.integer "effective_to_offset"
    t.string "employee_role"
    t.date "ends_on"
    t.bigint "shift_id", null: false
    t.bigint "shift_rule_profile_id"
    t.bigint "shift_template_id", null: false
    t.date "starts_on"
    t.datetime "updated_at", null: false
    t.integer "weekday"
    t.index ["branch_id"], name: "index_shift_template_entries_on_branch_id"
    t.index ["shift_id"], name: "index_shift_template_entries_on_shift_id"
    t.index ["shift_rule_profile_id"], name: "index_shift_template_entries_on_shift_rule_profile_id"
    t.index ["shift_template_id"], name: "index_shift_template_entries_on_shift_template_id"
    t.index ["weekday"], name: "index_shift_template_entries_on_weekday"
  end

  create_table "shift_templates", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "archived_at"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "name"], name: "index_shift_templates_on_business_id_and_name", unique: true
    t.index ["business_id"], name: "index_shift_templates_on_business_id"
    t.index ["created_by_id"], name: "index_shift_templates_on_created_by_id"
  end

  create_table "shifts", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "business_id", null: false
    t.datetime "created_at", null: false
    t.time "end_time"
    t.integer "max_early_leave_permission_minutes"
    t.integer "max_late_permission_minutes"
    t.string "name", null: false
    t.decimal "overtime_rate_multiplier", precision: 4, scale: 2
    t.decimal "required_hours", precision: 4, scale: 2
    t.string "shift_type", null: false
    t.time "start_time"
    t.datetime "updated_at", null: false
    t.index ["business_id", "name"], name: "index_shifts_on_business_id_and_name", unique: true
    t.index ["business_id"], name: "index_shifts_on_business_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.bigint "channel_hash", null: false
    t.datetime "created_at", null: false
    t.binary "payload", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "staff_closing_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "notes"
    t.bigint "payment_method_id", null: false
    t.decimal "refunds_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "sales_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.bigint "staff_closing_id", null: false
    t.datetime "updated_at", null: false
    t.index ["payment_method_id"], name: "index_staff_closing_entries_on_payment_method_id"
    t.index ["staff_closing_id", "payment_method_id"], name: "idx_staff_closing_entries_on_closing_and_method", unique: true
    t.index ["staff_closing_id"], name: "index_staff_closing_entries_on_staff_closing_id"
  end

  create_table "staff_closings", force: :cascade do |t|
    t.bigint "branch_id", null: false
    t.date "business_date", null: false
    t.decimal "closing_cash", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.bigint "daily_closing_id"
    t.text "expenses_notes"
    t.decimal "expenses_paid", precision: 12, scale: 2, default: "0.0", null: false
    t.text "notes"
    t.decimal "opening_cash", precision: 12, scale: 2, default: "0.0", null: false
    t.string "status", default: "open", null: false
    t.datetime "submitted_at"
    t.bigint "submitted_by_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.text "variance_note"
    t.index ["branch_id", "business_date"], name: "idx_staff_closings_branch_date"
    t.index ["branch_id", "status"], name: "idx_staff_closings_branch_status"
    t.index ["branch_id"], name: "index_staff_closings_on_branch_id"
    t.index ["daily_closing_id"], name: "idx_staff_closings_daily_closing"
    t.index ["daily_closing_id"], name: "index_staff_closings_on_daily_closing_id"
    t.index ["submitted_by_id"], name: "index_staff_closings_on_submitted_by_id"
    t.index ["user_id", "business_date"], name: "idx_staff_closings_user_date"
    t.index ["user_id"], name: "index_staff_closings_on_user_id"
  end

  create_table "stock_adjustment_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "product_id", null: false
    t.decimal "quantity_difference", precision: 12, scale: 3, null: false
    t.bigint "stock_adjustment_id", null: false
    t.decimal "total_cost", precision: 14, scale: 4, default: "0.0", null: false
    t.decimal "unit_cost", precision: 12, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_stock_adjustment_items_on_product_id"
    t.index ["stock_adjustment_id"], name: "index_stock_adjustment_items_on_stock_adjustment_id"
  end

  create_table "stock_adjustments", force: :cascade do |t|
    t.date "adjusted_on", null: false
    t.string "adjustment_number", null: false
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.text "notes"
    t.string "reason", null: false
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.bigint "warehouse_id", null: false
    t.index ["business_id", "adjustment_number"], name: "index_stock_adjustments_on_business_id_and_adjustment_number", unique: true
    t.index ["business_id"], name: "index_stock_adjustments_on_business_id"
    t.index ["created_by_id"], name: "index_stock_adjustments_on_created_by_id"
    t.index ["voided_by_id"], name: "index_stock_adjustments_on_voided_by_id"
    t.index ["warehouse_id"], name: "index_stock_adjustments_on_warehouse_id"
  end

  create_table "stock_count_items", force: :cascade do |t|
    t.decimal "counted_quantity", precision: 12, scale: 3
    t.datetime "created_at", null: false
    t.decimal "difference", precision: 12, scale: 3
    t.bigint "product_id", null: false
    t.bigint "stock_count_id", null: false
    t.decimal "system_quantity", precision: 12, scale: 3, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_stock_count_items_on_product_id"
    t.index ["stock_count_id", "product_id"], name: "index_stock_count_items_on_stock_count_id_and_product_id", unique: true
    t.index ["stock_count_id"], name: "index_stock_count_items_on_stock_count_id"
  end

  create_table "stock_counts", force: :cascade do |t|
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.bigint "business_id", null: false
    t.datetime "completed_at"
    t.bigint "completed_by_id"
    t.string "count_number", null: false
    t.date "counted_on", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.text "notes"
    t.datetime "started_at"
    t.string "status", default: "draft", null: false
    t.bigint "stock_adjustment_id"
    t.datetime "updated_at", null: false
    t.bigint "warehouse_id", null: false
    t.index ["approved_by_id"], name: "index_stock_counts_on_approved_by_id"
    t.index ["business_id", "count_number"], name: "index_stock_counts_on_business_id_and_count_number", unique: true
    t.index ["business_id"], name: "index_stock_counts_on_business_id"
    t.index ["completed_by_id"], name: "index_stock_counts_on_completed_by_id"
    t.index ["created_by_id"], name: "index_stock_counts_on_created_by_id"
    t.index ["stock_adjustment_id"], name: "index_stock_counts_on_stock_adjustment_id"
    t.index ["warehouse_id"], name: "index_stock_counts_on_warehouse_id"
  end

  create_table "stock_issue_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "product_id", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.bigint "stock_issue_id", null: false
    t.decimal "total_cost", precision: 14, scale: 4, default: "0.0", null: false
    t.decimal "unit_cost", precision: 12, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_stock_issue_items_on_product_id"
    t.index ["stock_issue_id"], name: "index_stock_issue_items_on_stock_issue_id"
  end

  create_table "stock_issues", force: :cascade do |t|
    t.bigint "branch_id"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.string "issue_number", null: false
    t.date "issued_on", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.bigint "warehouse_id", null: false
    t.index ["branch_id"], name: "index_stock_issues_on_branch_id"
    t.index ["business_id", "issue_number"], name: "index_stock_issues_on_business_id_and_issue_number", unique: true
    t.index ["business_id"], name: "index_stock_issues_on_business_id"
    t.index ["created_by_id"], name: "index_stock_issues_on_created_by_id"
    t.index ["voided_by_id"], name: "index_stock_issues_on_voided_by_id"
    t.index ["warehouse_id"], name: "index_stock_issues_on_warehouse_id"
  end

  create_table "stock_transfer_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "product_id", null: false
    t.decimal "quantity", precision: 12, scale: 3, null: false
    t.bigint "stock_transfer_id", null: false
    t.decimal "total_cost", precision: 14, scale: 4, default: "0.0", null: false
    t.decimal "unit_cost", precision: 12, scale: 4, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_stock_transfer_items_on_product_id"
    t.index ["stock_transfer_id"], name: "index_stock_transfer_items_on_stock_transfer_id"
  end

  create_table "stock_transfers", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.bigint "destination_warehouse_id", null: false
    t.text "notes"
    t.bigint "source_warehouse_id", null: false
    t.string "transfer_number", null: false
    t.date "transferred_on", null: false
    t.datetime "updated_at", null: false
    t.text "void_reason"
    t.datetime "voided_at"
    t.bigint "voided_by_id"
    t.index ["business_id", "transfer_number"], name: "index_stock_transfers_on_business_id_and_transfer_number", unique: true
    t.index ["business_id"], name: "index_stock_transfers_on_business_id"
    t.index ["created_by_id"], name: "index_stock_transfers_on_created_by_id"
    t.index ["destination_warehouse_id"], name: "index_stock_transfers_on_destination_warehouse_id"
    t.index ["source_warehouse_id"], name: "index_stock_transfers_on_source_warehouse_id"
    t.index ["voided_by_id"], name: "index_stock_transfers_on_voided_by_id"
  end

  create_table "suppliers", force: :cascade do |t|
    t.text "address"
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.decimal "latitude", precision: 10, scale: 6
    t.decimal "longitude", precision: 10, scale: 6
    t.string "name", null: false
    t.text "notes"
    t.string "primary_mobile"
    t.string "secondary_mobile"
    t.datetime "updated_at", null: false
    t.index ["business_id", "name"], name: "index_suppliers_on_business_id_and_name"
    t.index ["business_id"], name: "index_suppliers_on_business_id"
  end

  create_table "user_audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_id", null: false
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.bigint "target_user_id", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_user_audit_logs_on_action"
    t.index ["actor_id"], name: "index_user_audit_logs_on_actor_id"
    t.index ["created_at"], name: "index_user_audit_logs_on_created_at"
    t.index ["target_user_id"], name: "index_user_audit_logs_on_target_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "allow_biometric_attendance", default: true, null: false
    t.boolean "allow_mobile_attendance", default: true, null: false
    t.integer "business_id"
    t.datetime "created_at", null: false
    t.string "department"
    t.bigint "department_id"
    t.string "email"
    t.string "emergency_contact_name"
    t.string "emergency_contact_phone"
    t.string "emergency_contact_relationship"
    t.string "employee_code"
    t.string "employment_type"
    t.string "encrypted_password", default: "", null: false
    t.string "first_name"
    t.date "hire_date"
    t.date "identity_card_expiry_date"
    t.string "identity_card_number"
    t.string "job_title"
    t.string "last_name"
    t.jsonb "notification_preferences", default: {}, null: false
    t.integer "permission_role_id"
    t.string "phone_number"
    t.string "preferred_locale"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index "business_id, lower((employee_code)::text)", name: "index_users_on_business_id_and_lower_employee_code", unique: true, where: "((employee_code IS NOT NULL) AND ((employee_code)::text <> ''::text))"
    t.index ["business_id", "department"], name: "index_users_on_business_id_and_department"
    t.index ["business_id"], name: "index_users_on_business_id"
    t.index ["department_id"], name: "index_users_on_department_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["identity_card_number"], name: "index_users_on_identity_card_number", unique: true
    t.index ["permission_role_id"], name: "index_users_on_permission_role_id"
    t.index ["phone_number"], name: "index_users_on_phone_number", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "warehouse_assignments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "warehouse_id", null: false
    t.index ["user_id", "warehouse_id"], name: "index_warehouse_assignments_on_user_id_and_warehouse_id", unique: true
    t.index ["user_id"], name: "index_warehouse_assignments_on_user_id"
    t.index ["warehouse_id"], name: "index_warehouse_assignments_on_warehouse_id"
  end

  create_table "warehouses", force: :cascade do |t|
    t.bigint "business_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "name"], name: "index_warehouses_on_business_id_and_name"
    t.index ["business_id"], name: "index_warehouses_on_business_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "advances", "employee_requests"
  add_foreign_key "advances", "users"
  add_foreign_key "attendance_adjustments", "attendance_records"
  add_foreign_key "attendance_adjustments", "users", column: "adjusted_by_id"
  add_foreign_key "attendance_import_logs", "businesses"
  add_foreign_key "attendance_import_logs", "users", column: "imported_by_id"
  add_foreign_key "attendance_records", "branches"
  add_foreign_key "attendance_records", "shift_assignments"
  add_foreign_key "attendance_records", "users"
  add_foreign_key "audit_logs", "businesses"
  add_foreign_key "audit_logs", "users", column: "actor_id"
  add_foreign_key "balance_requests", "branches"
  add_foreign_key "balance_requests", "businesses"
  add_foreign_key "balance_requests", "users", column: "approved_by_id"
  add_foreign_key "balance_requests", "users", column: "cancelled_by_id"
  add_foreign_key "balance_requests", "users", column: "created_by_id"
  add_foreign_key "balance_requests", "users", column: "paid_by_id"
  add_foreign_key "bank_accounts", "branches"
  add_foreign_key "bank_accounts", "businesses"
  add_foreign_key "biometric_devices", "businesses"
  add_foreign_key "biometric_punch_logs", "attendance_records"
  add_foreign_key "biometric_punch_logs", "biometric_devices"
  add_foreign_key "biometric_punch_logs", "businesses"
  add_foreign_key "biometric_punch_logs", "users", column: "employee_id"
  add_foreign_key "branch_revenues", "branches"
  add_foreign_key "branch_revenues", "businesses"
  add_foreign_key "branch_revenues", "users", column: "created_by_id"
  add_foreign_key "branches", "businesses"
  add_foreign_key "branches", "users", column: "area_manager_id"
  add_foreign_key "branches", "users", column: "branch_manager_id"
  add_foreign_key "brands", "businesses"
  add_foreign_key "business_closing_locks", "businesses"
  add_foreign_key "business_closing_locks", "users", column: "locked_by_id"
  add_foreign_key "businesses", "users", column: "owner_id"
  add_foreign_key "cash_deposits", "bank_accounts"
  add_foreign_key "cash_deposits", "daily_closings"
  add_foreign_key "cash_deposits", "users", column: "deposited_by_id"
  add_foreign_key "cash_deposits", "users", column: "voided_by_id"
  add_foreign_key "cash_handovers", "daily_closings"
  add_foreign_key "cash_handovers", "staff_closings", column: "from_staff_closing_id"
  add_foreign_key "cash_handovers", "users", column: "from_user_id"
  add_foreign_key "cash_handovers", "users", column: "responded_by_id"
  add_foreign_key "cash_handovers", "users", column: "to_user_id"
  add_foreign_key "custody_accounts", "branches"
  add_foreign_key "custody_accounts", "businesses"
  add_foreign_key "custody_accounts", "users"
  add_foreign_key "custody_transactions", "businesses"
  add_foreign_key "custody_transactions", "custody_accounts"
  add_foreign_key "custody_transactions", "custody_transactions", column: "transfer_counterparty_id"
  add_foreign_key "custody_transactions", "expenses"
  add_foreign_key "custody_transactions", "users", column: "approved_by_id"
  add_foreign_key "custody_transactions", "users", column: "created_by_id"
  add_foreign_key "custody_transactions", "users", column: "voided_by_id"
  add_foreign_key "daily_closing_entries", "daily_closings"
  add_foreign_key "daily_closing_entries", "payment_methods"
  add_foreign_key "daily_closings", "branches"
  add_foreign_key "daily_closings", "businesses"
  add_foreign_key "daily_closings", "users", column: "submitted_by_id"
  add_foreign_key "daily_closings", "users", column: "verified_by_id"
  add_foreign_key "departments", "businesses"
  add_foreign_key "employee_obligations", "businesses"
  add_foreign_key "employee_obligations", "users"
  add_foreign_key "employee_obligations", "users", column: "created_by_id"
  add_foreign_key "employee_requests", "users"
  add_foreign_key "employee_requests", "users", column: "cancelled_by_id"
  add_foreign_key "employee_requests", "users", column: "reviewed_by_id"
  add_foreign_key "evaluation_criteria", "evaluation_templates"
  add_foreign_key "evaluation_templates", "businesses"
  add_foreign_key "evaluation_templates", "departments"
  add_foreign_key "expense_allocations", "branches"
  add_foreign_key "expense_allocations", "expenses"
  add_foreign_key "expense_categories", "businesses"
  add_foreign_key "expense_taggings", "expense_tags"
  add_foreign_key "expense_taggings", "expenses"
  add_foreign_key "expense_tags", "businesses"
  add_foreign_key "expense_types", "businesses"
  add_foreign_key "expense_types", "expense_categories"
  add_foreign_key "expenses", "branches"
  add_foreign_key "expenses", "businesses"
  add_foreign_key "expenses", "expense_categories"
  add_foreign_key "expenses", "expense_types"
  add_foreign_key "expenses", "recurring_expenses", column: "source_recurring_expense_id"
  add_foreign_key "expenses", "users", column: "approved_by_id"
  add_foreign_key "expenses", "users", column: "created_by_id"
  add_foreign_key "external_sales_imports", "branches"
  add_foreign_key "external_sales_imports", "businesses"
  add_foreign_key "external_sales_imports", "daily_closings"
  add_foreign_key "external_sales_imports", "users", column: "confirmed_by_id"
  add_foreign_key "external_sales_imports", "users", column: "uploaded_by_id"
  add_foreign_key "external_sales_rows", "external_sales_imports"
  add_foreign_key "external_sales_rows", "payment_methods"
  add_foreign_key "goods_receipt_items", "goods_receipts"
  add_foreign_key "goods_receipt_items", "products"
  add_foreign_key "goods_receipts", "businesses"
  add_foreign_key "goods_receipts", "suppliers"
  add_foreign_key "goods_receipts", "users", column: "created_by_id"
  add_foreign_key "goods_receipts", "users", column: "voided_by_id"
  add_foreign_key "goods_receipts", "warehouses"
  add_foreign_key "inventory_movements", "branches"
  add_foreign_key "inventory_movements", "businesses"
  add_foreign_key "inventory_movements", "products"
  add_foreign_key "inventory_movements", "warehouses"
  add_foreign_key "notifications", "users"
  add_foreign_key "obligation_deductions", "employee_obligations"
  add_foreign_key "obligation_deductions", "payroll_periods"
  add_foreign_key "payment_methods", "businesses"
  add_foreign_key "payroll_adjustments", "businesses"
  add_foreign_key "payroll_adjustments", "payroll_periods"
  add_foreign_key "payroll_adjustments", "users"
  add_foreign_key "payroll_adjustments", "users", column: "approved_by_id"
  add_foreign_key "payroll_adjustments", "users", column: "created_by_id"
  add_foreign_key "payroll_adjustments", "users", column: "rejected_by_id"
  add_foreign_key "payroll_adjustments", "users", column: "reviewed_by_id"
  add_foreign_key "payroll_audit_logs", "payroll_periods"
  add_foreign_key "payroll_audit_logs", "users", column: "actor_id"
  add_foreign_key "payroll_entries", "payroll_periods"
  add_foreign_key "payroll_entries", "users"
  add_foreign_key "payroll_line_items", "payroll_entries"
  add_foreign_key "payroll_line_items", "users", column: "reviewed_by_id"
  add_foreign_key "payroll_period_branch_reviews", "branches"
  add_foreign_key "payroll_period_branch_reviews", "payroll_periods"
  add_foreign_key "payroll_period_branch_reviews", "users", column: "reviewer_id"
  add_foreign_key "payroll_periods", "branches"
  add_foreign_key "payroll_periods", "businesses"
  add_foreign_key "payroll_periods", "users", column: "finalized_by_id"
  add_foreign_key "payroll_periods", "users", column: "generated_by_id"
  add_foreign_key "payroll_snapshots", "payroll_periods"
  add_foreign_key "payroll_snapshots", "users", column: "taken_by_id"
  add_foreign_key "penalty_rules", "shifts"
  add_foreign_key "performance_observations", "businesses"
  add_foreign_key "performance_observations", "evaluation_criteria"
  add_foreign_key "performance_observations", "users", column: "employee_id"
  add_foreign_key "performance_observations", "users", column: "observed_by_id"
  add_foreign_key "performance_review_scores", "evaluation_criteria"
  add_foreign_key "performance_review_scores", "performance_reviews"
  add_foreign_key "performance_reviews", "businesses"
  add_foreign_key "performance_reviews", "departments"
  add_foreign_key "performance_reviews", "users", column: "employee_id"
  add_foreign_key "performance_reviews", "users", column: "reviewer_id"
  add_foreign_key "permission_roles", "businesses"
  add_foreign_key "pos_terminals", "branches"
  add_foreign_key "pos_terminals", "businesses"
  add_foreign_key "product_barcodes", "businesses"
  add_foreign_key "product_barcodes", "product_variants", column: "variant_id"
  add_foreign_key "product_barcodes", "products"
  add_foreign_key "product_categories", "businesses"
  add_foreign_key "product_variants", "products"
  add_foreign_key "product_warehouse_settings", "products"
  add_foreign_key "product_warehouse_settings", "warehouses"
  add_foreign_key "products", "brands"
  add_foreign_key "products", "businesses"
  add_foreign_key "products", "product_categories"
  add_foreign_key "products", "products", column: "parent_product_id", on_delete: :nullify
  add_foreign_key "products", "suppliers", column: "default_supplier_id"
  add_foreign_key "recurring_expense_allocations", "branches"
  add_foreign_key "recurring_expense_allocations", "recurring_expenses"
  add_foreign_key "recurring_expenses", "branches"
  add_foreign_key "recurring_expenses", "businesses"
  add_foreign_key "recurring_expenses", "expense_categories"
  add_foreign_key "recurring_expenses", "expense_types"
  add_foreign_key "recurring_expenses", "users", column: "created_by_id"
  add_foreign_key "reopen_requests", "daily_closings"
  add_foreign_key "reopen_requests", "users", column: "requested_by_id"
  add_foreign_key "reopen_requests", "users", column: "reviewed_by_id"
  add_foreign_key "salary_profiles", "users"
  add_foreign_key "sales_mapping_profiles", "businesses"
  add_foreign_key "shift_assignments", "branches"
  add_foreign_key "shift_assignments", "shift_rule_profiles"
  add_foreign_key "shift_assignments", "shift_templates", column: "source_template_id"
  add_foreign_key "shift_assignments", "shifts"
  add_foreign_key "shift_assignments", "users"
  add_foreign_key "shift_assignments", "users", column: "created_by_id"
  add_foreign_key "shift_assignments", "users", column: "ended_by_id"
  add_foreign_key "shift_rule_profiles", "businesses"
  add_foreign_key "shift_template_entries", "branches"
  add_foreign_key "shift_template_entries", "shift_rule_profiles"
  add_foreign_key "shift_template_entries", "shift_templates"
  add_foreign_key "shift_template_entries", "shifts"
  add_foreign_key "shift_templates", "businesses"
  add_foreign_key "shift_templates", "users", column: "created_by_id"
  add_foreign_key "shifts", "businesses"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "staff_closing_entries", "payment_methods"
  add_foreign_key "staff_closing_entries", "staff_closings"
  add_foreign_key "staff_closings", "branches"
  add_foreign_key "staff_closings", "daily_closings"
  add_foreign_key "staff_closings", "users"
  add_foreign_key "staff_closings", "users", column: "submitted_by_id"
  add_foreign_key "stock_adjustment_items", "products"
  add_foreign_key "stock_adjustment_items", "stock_adjustments"
  add_foreign_key "stock_adjustments", "businesses"
  add_foreign_key "stock_adjustments", "users", column: "created_by_id"
  add_foreign_key "stock_adjustments", "users", column: "voided_by_id"
  add_foreign_key "stock_adjustments", "warehouses"
  add_foreign_key "stock_count_items", "products"
  add_foreign_key "stock_count_items", "stock_counts"
  add_foreign_key "stock_counts", "businesses"
  add_foreign_key "stock_counts", "stock_adjustments"
  add_foreign_key "stock_counts", "users", column: "approved_by_id"
  add_foreign_key "stock_counts", "users", column: "completed_by_id"
  add_foreign_key "stock_counts", "users", column: "created_by_id"
  add_foreign_key "stock_counts", "warehouses"
  add_foreign_key "stock_issue_items", "products"
  add_foreign_key "stock_issue_items", "stock_issues"
  add_foreign_key "stock_issues", "branches"
  add_foreign_key "stock_issues", "businesses"
  add_foreign_key "stock_issues", "users", column: "created_by_id"
  add_foreign_key "stock_issues", "users", column: "voided_by_id"
  add_foreign_key "stock_issues", "warehouses"
  add_foreign_key "stock_transfer_items", "products"
  add_foreign_key "stock_transfer_items", "stock_transfers"
  add_foreign_key "stock_transfers", "businesses"
  add_foreign_key "stock_transfers", "users", column: "created_by_id"
  add_foreign_key "stock_transfers", "users", column: "voided_by_id"
  add_foreign_key "stock_transfers", "warehouses", column: "destination_warehouse_id"
  add_foreign_key "stock_transfers", "warehouses", column: "source_warehouse_id"
  add_foreign_key "suppliers", "businesses"
  add_foreign_key "user_audit_logs", "users", column: "actor_id"
  add_foreign_key "user_audit_logs", "users", column: "target_user_id"
  add_foreign_key "users", "businesses"
  add_foreign_key "users", "departments"
  add_foreign_key "users", "permission_roles", on_delete: :nullify
  add_foreign_key "warehouse_assignments", "users"
  add_foreign_key "warehouse_assignments", "warehouses"
  add_foreign_key "warehouses", "businesses"
end
