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

ActiveRecord::Schema[8.1].define(version: 2026_05_21_200001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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

  create_table "attendance_records", force: :cascade do |t|
    t.integer "branch_id"
    t.datetime "check_in_at", null: false
    t.decimal "check_in_latitude", precision: 10, scale: 8
    t.decimal "check_in_longitude", precision: 11, scale: 8
    t.datetime "check_out_at"
    t.decimal "check_out_latitude", precision: 10, scale: 8
    t.decimal "check_out_longitude", precision: 11, scale: 8
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.integer "early_leave_minutes", default: 0, null: false
    t.integer "late_minutes", default: 0, null: false
    t.integer "shift_assignment_id"
    t.string "status", default: "incomplete", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.date "work_date", null: false
    t.integer "worked_minutes"
    t.index ["branch_id", "date"], name: "index_attendance_records_on_branch_id_and_date"
    t.index ["branch_id"], name: "index_attendance_records_on_branch_id"
    t.index ["shift_assignment_id"], name: "index_attendance_records_on_shift_assignment_id"
    t.index ["user_id", "status"], name: "index_attendance_records_on_user_id_and_status"
    t.index ["user_id", "work_date"], name: "index_attendance_records_on_user_id_and_work_date", unique: true
    t.index ["user_id"], name: "index_attendance_records_on_user_id"
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

  create_table "businesses", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "business_day_start_hour", default: 6, null: false
    t.datetime "created_at", null: false
    t.string "default_locale", default: "en", null: false
    t.integer "max_early_leave_permission_minutes"
    t.integer "max_late_permission_minutes"
    t.string "name", null: false
    t.bigint "owner_id"
    t.text "settings"
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.integer "working_days_per_month", default: 26, null: false
    t.index ["owner_id"], name: "index_businesses_on_owner_id"
  end

  create_table "employee_requests", force: :cascade do |t|
    t.boolean "affects_payroll", default: false, null: false
    t.decimal "amount", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.integer "duration_minutes"
    t.text "reason", null: false
    t.string "request_type", null: false
    t.date "requested_for_date", null: false
    t.text "response_note"
    t.datetime "reviewed_at"
    t.integer "reviewed_by_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["reviewed_by_id"], name: "index_employee_requests_on_reviewed_by_id"
    t.index ["user_id", "request_type", "requested_for_date"], name: "idx_on_user_id_request_type_requested_for_date_bed206bfdf"
    t.index ["user_id"], name: "index_employee_requests_on_user_id"
  end

  create_table "payroll_adjustments", force: :cascade do |t|
    t.string "adjustment_type", null: false
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "approved_at"
    t.integer "approved_by_id"
    t.integer "business_id", null: false
    t.datetime "created_at", null: false
    t.integer "created_by_id", null: false
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
    t.index ["business_id", "period_year", "period_month", "user_id"], name: "index_payroll_adjustments_on_period_and_user"
    t.index ["business_id"], name: "index_payroll_adjustments_on_business_id"
    t.index ["created_by_id"], name: "index_payroll_adjustments_on_created_by_id"
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
    t.decimal "base_salary", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.integer "days_worked", default: 0, null: false
    t.decimal "net_salary", precision: 12, scale: 2, null: false
    t.text "notes"
    t.integer "payroll_period_id", null: false
    t.string "salary_type", null: false
    t.string "status", default: "draft", null: false
    t.decimal "total_bonuses", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total_deductions", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "total_overtime", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "working_days", null: false
    t.index ["payroll_period_id", "user_id"], name: "index_payroll_entries_on_payroll_period_id_and_user_id", unique: true
    t.index ["payroll_period_id"], name: "index_payroll_entries_on_payroll_period_id"
    t.index ["user_id", "status"], name: "index_payroll_entries_on_user_id_and_status"
    t.index ["user_id"], name: "index_payroll_entries_on_user_id"
  end

  create_table "payroll_line_items", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
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
    t.index ["business_id", "period_year", "period_month"], name: "index_payroll_periods_unique", unique: true
    t.index ["business_id"], name: "index_payroll_periods_on_business_id"
    t.index ["finalized_by_id"], name: "index_payroll_periods_on_finalized_by_id"
    t.index ["generated_by_id"], name: "index_payroll_periods_on_generated_by_id"
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

  create_table "permission_roles", force: :cascade do |t|
    t.integer "business_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.jsonb "permissions", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["business_id", "name"], name: "index_permission_roles_on_business_id_and_name", unique: true
    t.index ["business_id"], name: "index_permission_roles_on_business_id"
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

  create_table "shift_assignments", force: :cascade do |t|
    t.integer "branch_id"
    t.datetime "created_at", null: false
    t.date "effective_from", null: false
    t.date "effective_to"
    t.integer "shift_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["branch_id"], name: "index_shift_assignments_on_branch_id"
    t.index ["shift_id"], name: "index_shift_assignments_on_shift_id"
    t.index ["user_id", "branch_id"], name: "index_shift_assignments_on_user_id_and_branch_id"
    t.index ["user_id", "effective_from"], name: "index_shift_assignments_on_user_id_and_effective_from"
    t.index ["user_id"], name: "index_shift_assignments_on_user_id"
  end

  create_table "shifts", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "business_id", null: false
    t.datetime "created_at", null: false
    t.time "end_time"
    t.string "name", null: false
    t.decimal "overtime_rate_multiplier", precision: 4, scale: 2, default: "1.5", null: false
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

  create_table "user_branches", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.integer "branch_id", null: false
    t.datetime "created_at", null: false
    t.date "joined_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["branch_id"], name: "index_user_branches_on_branch_id"
    t.index ["user_id", "branch_id"], name: "index_user_branches_on_user_id_and_branch_id", unique: true
    t.index ["user_id"], name: "index_user_branches_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "allow_biometric_attendance", default: true, null: false
    t.boolean "allow_mobile_attendance", default: true, null: false
    t.integer "business_id"
    t.datetime "created_at", null: false
    t.string "email"
    t.string "emergency_contact_name"
    t.string "emergency_contact_phone"
    t.string "emergency_contact_relationship"
    t.string "employee_code"
    t.string "encrypted_password", default: "", null: false
    t.string "first_name"
    t.date "identity_card_expiry_date"
    t.string "identity_card_number"
    t.string "last_name"
    t.integer "manager_id"
    t.integer "permission_role_id"
    t.string "phone_number"
    t.string "preferred_locale"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index "business_id, lower((employee_code)::text)", name: "index_users_on_business_id_and_lower_employee_code", unique: true, where: "((employee_code IS NOT NULL) AND ((employee_code)::text <> ''::text))"
    t.index ["business_id"], name: "index_users_on_business_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["identity_card_number"], name: "index_users_on_identity_card_number", unique: true
    t.index ["manager_id"], name: "index_users_on_manager_id"
    t.index ["permission_role_id"], name: "index_users_on_permission_role_id"
    t.index ["phone_number"], name: "index_users_on_phone_number", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "advances", "employee_requests"
  add_foreign_key "advances", "users"
  add_foreign_key "attendance_adjustments", "attendance_records"
  add_foreign_key "attendance_adjustments", "users", column: "adjusted_by_id"
  add_foreign_key "attendance_records", "branches"
  add_foreign_key "attendance_records", "shift_assignments"
  add_foreign_key "attendance_records", "users"
  add_foreign_key "biometric_devices", "businesses"
  add_foreign_key "biometric_punch_logs", "attendance_records"
  add_foreign_key "biometric_punch_logs", "biometric_devices"
  add_foreign_key "biometric_punch_logs", "businesses"
  add_foreign_key "biometric_punch_logs", "users", column: "employee_id"
  add_foreign_key "branches", "businesses"
  add_foreign_key "branches", "users", column: "area_manager_id"
  add_foreign_key "branches", "users", column: "branch_manager_id"
  add_foreign_key "businesses", "users", column: "owner_id"
  add_foreign_key "employee_requests", "users"
  add_foreign_key "employee_requests", "users", column: "reviewed_by_id"
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
  add_foreign_key "penalty_rules", "shifts"
  add_foreign_key "permission_roles", "businesses"
  add_foreign_key "salary_profiles", "users"
  add_foreign_key "shift_assignments", "branches"
  add_foreign_key "shift_assignments", "shifts"
  add_foreign_key "shift_assignments", "users"
  add_foreign_key "shifts", "businesses"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "user_audit_logs", "users", column: "actor_id"
  add_foreign_key "user_audit_logs", "users", column: "target_user_id"
  add_foreign_key "user_branches", "branches"
  add_foreign_key "user_branches", "users"
  add_foreign_key "users", "businesses"
  add_foreign_key "users", "permission_roles", on_delete: :nullify
  add_foreign_key "users", "users", column: "manager_id", on_delete: :nullify
end
