# Idempotent seed data for development and demo environments.
# Run with: bin/rails db:seed
# Reset and reseed: bin/rails db:seed:replant  (or db:reset && db:seed)

puts "\n== WorkPulse Seed Data =="

# ---------------------------------------------------------------------------
# Business
# ---------------------------------------------------------------------------
business = Business.find_or_create_by!(name: "Al-Noor Group") do |b|
  b.timezone               = "Asia/Riyadh"
  b.working_days_per_month = 26
  b.active                 = true
end
puts "Business: #{business.name}"

# ---------------------------------------------------------------------------
# Branches
# ---------------------------------------------------------------------------
riyadh = Branch.find_or_create_by!(name: "Riyadh HQ", business: business) do |b|
  b.address             = "King Fahd Road, Al Olaya, Riyadh"
  b.geolocation_enabled = true
  b.latitude            = 24.6877
  b.longitude           = 46.7219
  b.radius_meters       = 200
  b.active              = true
end

jeddah = Branch.find_or_create_by!(name: "Jeddah Branch", business: business) do |b|
  b.address             = "Tahlia Street, Al Rawdah, Jeddah"
  b.geolocation_enabled = false
  b.active              = true
end
puts "Branches: #{riyadh.name}, #{jeddah.name}"

# ---------------------------------------------------------------------------
# Shifts
# ---------------------------------------------------------------------------
morning_shift = Shift.find_or_create_by!(name: "Morning Shift", business: business) do |s|
  s.shift_type               = "fixed_time"
  s.start_time               = Time.zone.parse("09:00")
  s.end_time                 = Time.zone.parse("17:00")
  s.overtime_rate_multiplier = 1.5
  s.active                   = true
end

flexible_shift = Shift.find_or_create_by!(name: "Flexible Shift", business: business) do |s|
  s.shift_type               = "hour_based"
  s.required_hours           = 8
  s.overtime_rate_multiplier = 1.25
  s.active                   = true
end
puts "Shifts: #{morning_shift.name}, #{flexible_shift.name}"

# ---------------------------------------------------------------------------
# Penalty rules for Morning Shift
# ---------------------------------------------------------------------------
unless morning_shift.penalty_rules.for_late_arrival.exists?
  PenaltyRule.create!(shift: morning_shift, rule_type: "late_arrival", deduction_type: "percentage_of_daily",
                      threshold_minutes: 15, deduction_value: 25)
  PenaltyRule.create!(shift: morning_shift, rule_type: "late_arrival", deduction_type: "percentage_of_daily",
                      threshold_minutes: 60, deduction_value: 50)
end

unless morning_shift.penalty_rules.for_early_leave.exists?
  PenaltyRule.create!(shift: morning_shift, rule_type: "early_leave", deduction_type: "percentage_of_daily",
                      threshold_minutes: 30, deduction_value: 25)
end
puts "Penalty rules: #{morning_shift.penalty_rules.count} rules for #{morning_shift.name}"

# ---------------------------------------------------------------------------
# Users helper
# ---------------------------------------------------------------------------
def seed_user(business:, email:, phone: nil, first_name:, last_name:,
              employee_code: nil, identity_card_number: nil)
  user = User.find_by(email: email) || (phone && User.find_by(phone_number: phone))
  if user.nil?
    user = User.create!(
      business:              business,
      email:                 email,
      phone_number:          phone,
      first_name:            first_name,
      last_name:             last_name,
      employee_code:         employee_code,
      identity_card_number:  identity_card_number,
      password:              "password123",
      password_confirmation: "password123",
      active:                true
    )
  end
  user
end

# ---------------------------------------------------------------------------
# Super Admin
# ---------------------------------------------------------------------------
admin = seed_user(
  business:             business,
  email:                "admin@workpulse.dev",
  first_name:           "Sara",
  last_name:            "Al-Otaibi",
  employee_code:        "ADM-001",
  identity_card_number: "1001000001"
)
business.update_column(:owner_id, admin.id) if business.owner_id.nil?
puts "Owner: #{admin.email}"

# ---------------------------------------------------------------------------
# Area Manager
# ---------------------------------------------------------------------------
area_mgr = seed_user(
  business:             business,
  email:                "area.manager@workpulse.dev",
  phone:                "+966509990002",
  first_name:           "Tariq",
  last_name:            "Al-Harbi",
  employee_code:        "ARM-001",
  identity_card_number: "1001000002"
)
puts "Area Manager: #{area_mgr.email}"

# ---------------------------------------------------------------------------
# Accountant
# ---------------------------------------------------------------------------
accountant = seed_user(
  business:             business,
  email:                "accountant@workpulse.dev",
  phone:                "+966509990001",
  first_name:           "Hana",
  last_name:            "Al-Rashid",
  employee_code:        "ACC-001",
  identity_card_number: "1001000003"
)
puts "Accountant: #{accountant.email}"

# ---------------------------------------------------------------------------
# Branch Managers
# ---------------------------------------------------------------------------
mgr_riyadh = seed_user(
  business:             business,
  email:                "manager.riyadh@workpulse.dev",
  phone:                "+966501110001",
  first_name:           "Khaled",
  last_name:            "Al-Ghamdi",
  employee_code:        "MGR-001",
  identity_card_number: "1001000004"
)

mgr_jeddah = seed_user(
  business:             business,
  email:                "manager.jeddah@workpulse.dev",
  phone:                "+966501110002",
  first_name:           "Noura",
  last_name:            "Al-Zahrani",
  employee_code:        "MGR-002",
  identity_card_number: "1001000005"
)
puts "Managers: #{mgr_riyadh.email}, #{mgr_jeddah.email}"

# ---------------------------------------------------------------------------
# Employees
# ---------------------------------------------------------------------------
employees_data = [
  { email: "ahmed.hassan@workpulse.dev",  phone: "+966502220001", first_name: "Ahmed",  last_name: "Hassan",   branch: riyadh, shift: morning_shift,  salary_type: "monthly", amount: 8_000, code: "EMP-001", ic: "1012345678" },
  { email: "fatima.ali@workpulse.dev",    phone: "+966502220002", first_name: "Fatima", last_name: "Ali",      branch: riyadh, shift: morning_shift,  salary_type: "monthly", amount: 7_500, code: "EMP-002", ic: "1023456789" },
  { email: "omar.nasser@workpulse.dev",   phone: "+966502220003", first_name: "Omar",   last_name: "Nasser",   branch: riyadh, shift: flexible_shift, salary_type: "daily",   amount: 350,   code: "EMP-003", ic: "1034567890" },
  { email: "layla.ibrahim@workpulse.dev", phone: "+966502220004", first_name: "Layla",  last_name: "Ibrahim",  branch: jeddah, shift: morning_shift,  salary_type: "monthly", amount: 6_500, code: "EMP-004", ic: "2045678901" },
  { email: "yusuf.karimi@workpulse.dev",  phone: "+966502220005", first_name: "Yusuf",  last_name: "Karimi",   branch: jeddah, shift: flexible_shift, salary_type: "daily",   amount: 300,   code: "EMP-005", ic: "2056789012" },
  { email: "reem.sultan@workpulse.dev",   phone: "+966502220006", first_name: "Reem",   last_name: "Sultan",   branch: jeddah, shift: morning_shift,  salary_type: "monthly", amount: 7_000, code: "EMP-006", ic: "2067890123" }
]

employees = employees_data.map do |d|
  seed_user(
    business:             business,
    email:                d[:email],
    phone:                d[:phone],
    first_name:           d[:first_name],
    last_name:            d[:last_name],
    employee_code:        d[:code],
    identity_card_number: d[:ic]
  )
end
puts "Employees: #{employees.count} created/found"

emp1 = employees[0]  # Ahmed Hassan   — Riyadh, monthly 8000
emp2 = employees[1]  # Fatima Ali     — Riyadh, monthly 7500
emp3 = employees[2]  # Omar Nasser    — Riyadh, daily 350
emp4 = employees[3]  # Layla Ibrahim  — Jeddah, monthly 6500
emp5 = employees[4]  # Yusuf Karimi   — Jeddah, daily 300
emp6 = employees[5]  # Reem Sultan    — Jeddah, monthly 7000

# ---------------------------------------------------------------------------
# Branch manager relationships (membership itself is shift-driven via ShiftAssignment)
# ---------------------------------------------------------------------------
riyadh.update_column(:branch_manager_id, mgr_riyadh.id) if riyadh.branch_manager_id.nil?
jeddah.update_column(:branch_manager_id, mgr_jeddah.id) if jeddah.branch_manager_id.nil?
puts "Branch manager relationships set"

# Management hierarchy is derived from Branch.branch_manager_id / area_manager_id
# and active ShiftAssignments — there is no direct employee→manager ownership.

# Assign area manager to both branches
riyadh.update_column(:area_manager_id, area_mgr.id) if riyadh.area_manager_id.nil?
jeddah.update_column(:area_manager_id, area_mgr.id) if jeddah.area_manager_id.nil?

puts "Hierarchy: employees → branch managers → #{area_mgr.full_name} → #{admin.full_name}"

# ---------------------------------------------------------------------------
# Salary profiles
# ---------------------------------------------------------------------------
all_staff = employees + [ mgr_riyadh, mgr_jeddah ]
all_staff.each_with_index do |user, i|
  next if SalaryProfile.where(user: user, active: true).exists?

  data = employees_data[i] || { salary_type: "monthly", amount: 9_000 }
  SalaryProfile.create!(
    user:           user,
    salary_type:    data[:salary_type],
    base_amount:    data[:amount],
    currency:       business.currency,
    effective_from: 1.year.ago.to_date,
    active:         true
  )
end
puts "Salary profiles assigned"

# ---------------------------------------------------------------------------
# Shift assignments
# ---------------------------------------------------------------------------
employees_data.each_with_index do |d, i|
  user   = employees[i]
  branch = d[:branch]
  shift  = d[:shift]
  next if ShiftAssignment.active_on(Date.current).where(user: user, branch: branch).exists?

  ShiftAssignment.create!(
    user:           user,
    shift:          shift,
    branch:         branch,
    effective_from: 6.months.ago.to_date
  )
end

[ [ mgr_riyadh, riyadh ], [ mgr_jeddah, jeddah ] ].each do |user, branch|
  next if ShiftAssignment.active_on(Date.current).where(user: user, branch: branch).exists?

  ShiftAssignment.create!(
    user:           user,
    shift:          morning_shift,
    branch:         branch,
    effective_from: 6.months.ago.to_date
  )
end
puts "Shift assignments created"

# ---------------------------------------------------------------------------
# Attendance records — last 30 working days
# ---------------------------------------------------------------------------
def working_days_back(n)
  days = []
  date = Date.current - 1
  while days.size < n
    days << date unless date.saturday? || date.sunday?
    date -= 1
  end
  days
end

work_dates = working_days_back(30)

employees_data.each_with_index do |d, i|
  user             = employees[i]
  branch           = d[:branch]
  shift_assignment = ShiftAssignment.active_on(Date.current).find_by(user: user, branch: branch)
  next unless shift_assignment

  shift = shift_assignment.shift

  work_dates.each do |date|
    next if AttendanceRecord.where(user: user, date: date).exists?

    roll = rand(100)
    next if roll < 10  # ~10% absent

    if shift.fixed_time?
      scheduled_in  = Time.zone.local(date.year, date.month, date.day, 9, 0, 0)
      scheduled_out = Time.zone.local(date.year, date.month, date.day, 17, 0, 0)

      late_mins = roll < 25 ? rand(16..90) : 0
      early_out = roll < 40 ? rand(31..120) : 0

      check_in  = scheduled_in  + late_mins.minutes + rand(-2..2).minutes
      check_out = scheduled_out - early_out.minutes  + rand(-5..5).minutes

      worked = ((check_out - check_in) / 60).to_i.clamp(0, 9_999)
      status = late_mins >= 15 ? "late" : (early_out >= 30 ? "early_leave" : "present")
    else
      check_in  = Time.zone.local(date.year, date.month, date.day, rand(7..9), rand(0..59), 0)
      worked    = rand(420..540)
      check_out = check_in + worked.minutes
      late_mins = 0
      early_out = 0
      status    = worked >= 480 ? "present" : "early_leave"
    end

    AttendanceRecord.create!(
      user:                user,
      branch:              branch,
      shift_assignment:    shift_assignment,
      date:                date,
      work_date:           date,
      check_in_at:         check_in,
      check_out_at:        check_out,
      status:              status,
      worked_minutes:      worked,
      late_minutes:        late_mins,
      early_leave_minutes: early_out
    )
  end
end
puts "Attendance records seeded for last 30 working days"

# ---------------------------------------------------------------------------
# Employee Requests — covering all statuses and types
# ---------------------------------------------------------------------------

# 1. Pending late_permission — waiting manager approval
unless EmployeeRequest.where(user: emp1, request_type: "late_permission", status: "pending").exists?
  EmployeeRequest.create!(
    user:               emp1,
    request_type:       "late_permission",
    requested_for_date: Date.current + 2.days,
    reason:             "Medical appointment in the morning",
    duration_minutes:   60,
    status:             "pending"
  )
end

# 2. Pending salary_advance — waiting manager approval
unless EmployeeRequest.where(user: emp3, request_type: "salary_advance", status: "pending").exists?
  EmployeeRequest.create!(
    user:               emp3,
    request_type:       "salary_advance",
    requested_for_date: Date.current,
    reason:             "Urgent home repair",
    amount:             1_500,
    status:             "pending"
  )
end

# 3. Approved salary_advance — manager approved, awaiting accountant disbursement
unless EmployeeRequest.where(user: emp2, request_type: "salary_advance", status: "approved").exists?
  EmployeeRequest.create!(
    user:               emp2,
    request_type:       "salary_advance",
    requested_for_date: Date.current - 2.days,
    reason:             "School fees for children",
    amount:             2_500,
    status:             "approved",
    reviewed_by:        mgr_riyadh,
    reviewed_at:        Time.current - 2.days,
    response_note:      "Approved. Will be deducted from next 2 payrolls."
  )
end

# 4. Paid salary_advance — disbursed by accountant; Advance record created
unless EmployeeRequest.where(user: emp4, request_type: "salary_advance", status: "paid").exists?
  paid_req = EmployeeRequest.create!(
    user:               emp4,
    request_type:       "salary_advance",
    requested_for_date: Date.current - 10.days,
    reason:             "Car repair emergency",
    amount:             2_000,
    status:             "paid",
    reviewed_by:        mgr_jeddah,
    reviewed_at:        Time.current - 9.days,
    response_note:      "Approved.",
    affects_payroll:    true
  )
  Advance.find_or_create_by!(employee_request: paid_req) do |a|
    a.user             = emp4
    a.total_amount     = 2_000
    a.remaining_amount = 1_000
    a.issued_at        = Time.current - 9.days
    a.status           = "active"
  end
end

# 5. Rejected early_leave
unless EmployeeRequest.where(user: emp2, request_type: "early_leave", status: "rejected").exists?
  EmployeeRequest.create!(
    user:               emp2,
    request_type:       "early_leave",
    requested_for_date: Date.current - 3.days,
    reason:             "Family obligation",
    duration_minutes:   90,
    status:             "rejected",
    reviewed_by:        mgr_riyadh,
    reviewed_at:        Time.current - 2.days,
    response_note:      "Cannot be accommodated during peak hours."
  )
end

# 6. Approved early_leave (affects_payroll — should exempt from penalty)
unless EmployeeRequest.where(user: emp5, request_type: "early_leave", status: "approved").exists?
  EmployeeRequest.create!(
    user:               emp5,
    request_type:       "early_leave",
    requested_for_date: Date.current - 1.day,
    reason:             "Medical follow-up",
    duration_minutes:   45,
    status:             "approved",
    reviewed_by:        mgr_jeddah,
    reviewed_at:        Time.current - 1.day,
    affects_payroll:    true
  )
end

puts "Employee requests seeded (pending/approved/paid/rejected)"

# ---------------------------------------------------------------------------
# Payroll helper
# ---------------------------------------------------------------------------
def build_payroll_entry(payroll_period:, user:, admin:)
  return if PayrollEntry.where(payroll_period: payroll_period, user: user).exists?

  profile = SalaryProfile.current_for(user)
  return unless profile

  period_start = payroll_period.period_start
  period_end   = payroll_period.period_end

  days_worked = AttendanceRecord
    .where(user: user)
    .for_period(period_start, period_end)
    .where(status: %w[present late early_leave])
    .count

  total_late_mins = AttendanceRecord
    .where(user: user)
    .for_period(period_start, period_end)
    .sum(:late_minutes)

  base  = profile.base_amount
  daily = profile.monthly? ? (base / 22.0).round(2) : base.to_f

  late_deduction = ((total_late_mins / 60.0) * (daily / 8.0)).round(2)

  advance_record   = Advance.active.find_by(user: user)
  advance_deducted = advance_record ? [ advance_record.remaining_amount * 0.5, 500 ].min.round(2) : 0.0

  net = (profile.monthly? ? base : daily * days_worked) - late_deduction - advance_deducted

  entry = PayrollEntry.create!(
    payroll_period:    payroll_period,
    user:              user,
    salary_type:       profile.salary_type,
    base_salary:       base,
    working_days:      22,
    days_worked:       days_worked,
    total_deductions:  late_deduction,
    advances_deducted: advance_deducted,
    total_bonuses:     0,
    total_overtime:    0,
    net_salary:        [ net, 0 ].max
  )

  if late_deduction > 0
    PayrollLineItem.create!(
      payroll_entry: entry,
      item_type:     "late_penalty",
      amount:        -late_deduction,
      description:   "Late arrival deduction (#{total_late_mins} min)",
      review_status: "approved"
    )
  end

  if advance_deducted > 0
    PayrollLineItem.create!(
      payroll_entry: entry,
      item_type:     "advance_deduction",
      amount:        -advance_deducted,
      description:   "Salary advance instalment",
      review_status: "approved"
    )
    advance_record.repay!(advance_deducted)
  end

  entry
end

# ---------------------------------------------------------------------------
# Payroll Period 1 — Two months ago: branch_review_completed (company-wide)
# ---------------------------------------------------------------------------
two_months_ago = Date.current.prev_month.prev_month
period_2m = PayrollPeriod.find_or_create_by!(
  business:     business,
  period_year:  two_months_ago.year,
  period_month: two_months_ago.month
) do |p|
  p.working_days  = 22
  p.status        = "branch_review_completed"
  p.generated_by  = admin
  p.generated_at  = Time.current - 35.days
end

employees.each { |user| build_payroll_entry(payroll_period: period_2m, user: user, admin: admin) }

{ mgr_riyadh => riyadh, mgr_jeddah => jeddah }.each do |reviewer, branch|
  unless PayrollPeriodBranchReview.where(payroll_period: period_2m, branch: branch).exists?
    PayrollPeriodBranchReview.create!(
      payroll_period: period_2m,
      branch:         branch,
      reviewer:       reviewer,
      status:         "completed",
      completed_at:   Time.current - 30.days,
      notes:          "All entries reviewed and confirmed."
    )
  end
end
puts "Payroll period (branch_review_completed): #{period_2m.period_label}"

# ---------------------------------------------------------------------------
# Payroll Period 2 — Last month: finalized (business-wide)
# ---------------------------------------------------------------------------
last_month = Date.current.prev_month
period_lm  = PayrollPeriod.find_or_create_by!(
  business:     business,
  period_year:  last_month.year,
  period_month: last_month.month,
  branch:       nil
) do |p|
  p.working_days  = 22
  p.status        = "finalized"
  p.generated_by  = admin
  p.generated_at  = Time.current - 10.days
  p.finalized_by  = admin
  p.finalized_at  = Time.current - 5.days
end

entries_lm = employees.map { |u| build_payroll_entry(payroll_period: period_lm, user: u, admin: admin) }.compact

# Waived deduction — emp1's late penalty was waived by manager
emp1_entry = PayrollEntry.find_by(payroll_period: period_lm, user: emp1)
if emp1_entry
  waived_item = emp1_entry.payroll_line_items.find_by(item_type: "late_penalty", review_status: "approved")
  if waived_item
    waived_item.update!(review_status: "rejected", review_notes: "Waived — traffic accident on highway", reviewed_by: admin, reviewed_at: Time.current - 6.days)
    emp1_entry.recalculate_totals!
  end
end

# Approved bonus — emp6 received a performance bonus (approved by admin)
emp6_entry = PayrollEntry.find_by(payroll_period: period_lm, user: emp6)
if emp6_entry && emp6_entry.payroll_line_items.where(item_type: "bonus").none?
  bonus_adj = PayrollAdjustment.find_by(
    business:        business,
    period_year:     period_lm.period_year,
    period_month:    period_lm.period_month,
    user:            emp6,
    adjustment_type: "bonus"
  )
  unless bonus_adj
    bonus_adj = PayrollAdjustment.new(
      payroll_period:  period_lm,
      business:        business,
      period_month:    period_lm.period_month,
      period_year:     period_lm.period_year,
      user:            emp6,
      adjustment_type: "bonus",
      amount:          500,
      reason:          "Exceptional performance — Ramadan rush",
      created_by:      mgr_jeddah,
      review_status:   "approved",
      approved_by:     admin,
      approved_at:     Time.current - 6.days,
      reviewed_by:     admin,
      reviewed_at:     Time.current - 6.days,
      review_notes:    "Approved. Well deserved."
    )
    bonus_adj.save!(validate: false)  # bypass lock check for historical seeding
  end

  unless emp6_entry.payroll_line_items.where(item_type: "bonus", source_type: "PayrollAdjustment", source_id: bonus_adj.id).exists?
    # PayrollLineItem.create!(
    #   payroll_entry: emp6_entry,
    #   item_type:     "bonus",
    #   amount:        500,
    #   description:   "Performance bonus — Ramadan rush",
    #   review_status: "approved",
    #   reviewed_by:   admin,
    #   reviewed_at:   Time.current - 6.days,
    #   source_type:   "PayrollAdjustment",
    #   source_id:     bonus_adj.id
    # )
  end
  emp6_entry.recalculate_totals!
end

puts "Payroll period (finalized): #{period_lm.period_label}"

# ---------------------------------------------------------------------------
# Payroll Period 3 — Current month: draft
# ---------------------------------------------------------------------------
this_month  = Date.current
period_curr = PayrollPeriod.find_or_create_by!(
  business:     business,
  period_year:  this_month.year,
  period_month: this_month.month,
  branch:       nil
) do |p|
  p.working_days = 22
  p.status       = "draft"
  p.generated_by = admin
  p.generated_at = Time.current
end

employees.each { |u| build_payroll_entry(payroll_period: period_curr, user: u, admin: admin) }

# Pending manual deduction — emp4 uniform damage (submitted by manager, awaiting admin approval)
emp4_curr = PayrollEntry.find_by(payroll_period: period_curr, user: emp4)
if emp4_curr
  unless PayrollAdjustment.where(business: business, period_year: period_curr.period_year,
                                  period_month: period_curr.period_month,
                                  user: emp4, adjustment_type: "manual_deduction").exists?
    deduction_adj = PayrollAdjustment.create!(
      payroll_period:  period_curr,
      business:        business,
      period_month:    period_curr.period_month,
      period_year:     period_curr.period_year,
      user:            emp4,
      adjustment_type: "manual_deduction",
      amount:          150,
      reason:          "Uniform damage deduction",
      created_by:      mgr_jeddah,
      review_status:   "pending_review"
    )
    PayrollLineItem.create!(
      payroll_entry: emp4_curr,
      item_type:     "manual_deduction",
      amount:        -150,
      description:   "Uniform damage deduction (pending review)",
      review_status: "pending_review",
      source_type:   "PayrollAdjustment",
      source_id:     deduction_adj.id
    )
  end
end

# Pending bonus — emp1 outstanding attendance (submitted by manager, awaiting admin approval)
emp1_curr = PayrollEntry.find_by(payroll_period: period_curr, user: emp1)
if emp1_curr
  unless PayrollAdjustment.where(business: business, period_year: period_curr.period_year,
                                  period_month: period_curr.period_month,
                                  user: emp1, adjustment_type: "bonus").exists?
    # bonus_curr = PayrollAdjustment.create!(
    #   payroll_period:  period_curr,
    #   business:        business,
    #   period_month:    period_curr.period_month,
    #   period_year:     period_curr.period_year,
    #   user:            emp1,
    #   adjustment_type: "bonus",
    #   amount:          300,
    #   reason:          "Outstanding attendance — perfect month",
    #   created_by:      mgr_riyadh,
    #   review_status:   "pending_review"
    # )
    # PayrollLineItem.create!(
    #   payroll_entry: emp1_curr,
    #   item_type:     "bonus",
    #   amount:        300,
    #   description:   "Attendance bonus (pending review)",
    #   review_status: "pending_review",
    #   source_type:   "PayrollAdjustment",
    #   source_id:     bonus_curr.id
    # )
  end
end

puts "Payroll period (draft): #{period_curr.period_label}"

# ===========================================================================
# INVENTORY
# ---------------------------------------------------------------------------
# Reference data (warehouses, suppliers, categories, brands, products) is
# created idempotently with find_or_create_by. The stock itself is built only
# on a fresh database (guarded by "no inventory movements yet") and is posted
# through the real Inventory service objects — GoodsReceiptPoster, transfers,
# issues, adjustments and a posted stock count — so the movement ledger, moving
# average cost and document numbers are all produced exactly as in production.
# ===========================================================================

# ---------------------------------------------------------------------------
# Warehouses (business-scoped; conceptually mapped to branches + a central DC)
# ---------------------------------------------------------------------------
w_main = Warehouse.find_or_create_by!(business: business, name: "Riyadh Main Warehouse") do |w|
  w.description = "Primary stockroom serving the Riyadh HQ salon floor"
  w.status      = "active"
end

w_jeddah = Warehouse.find_or_create_by!(business: business, name: "Jeddah Branch Warehouse") do |w|
  w.description = "Back-of-house storage for the Jeddah branch"
  w.status      = "active"
end

w_central = Warehouse.find_or_create_by!(business: business, name: "Central Distribution Center") do |w|
  w.description = "Bulk warehouse that supplies both branches via transfers"
  w.status      = "active"
end
warehouses = [ w_main, w_jeddah, w_central ]
puts "Warehouses: #{warehouses.map(&:name).join(', ')}"

# Warehouse scoping demo: the Jeddah manager only sees the Jeddah warehouse.
# (A user with no assignments sees every warehouse — owners/accountants.)
WarehouseAssignment.find_or_create_by!(user: mgr_jeddah, warehouse: w_jeddah)
puts "Warehouse assignments: #{mgr_jeddah.full_name} → #{w_jeddah.name}"

# ---------------------------------------------------------------------------
# Suppliers
# ---------------------------------------------------------------------------
suppliers_data = [
  { name: "Gulf Beauty Supplies",          mobile: "+966112340001", address: "Industrial City 2, Riyadh",   lat: 24.6500, lng: 46.7100 },
  { name: "Al-Salam Trading Co.",          mobile: "+966122340002", address: "Al Khomrah District, Jeddah",  lat: 21.4200, lng: 39.1900 },
  { name: "Riyadh Cosmetics Distribution", mobile: "+966112340003", address: "Exit 18, Eastern Ring Road, Riyadh", lat: nil, lng: nil }
]
suppliers = suppliers_data.map do |d|
  Supplier.find_or_create_by!(business: business, name: d[:name]) do |s|
    s.primary_mobile = d[:mobile]
    s.address        = d[:address]
    s.latitude       = d[:lat]
    s.longitude      = d[:lng]
  end
end
sup_gulf, sup_salam, sup_cosmetics = suppliers
puts "Suppliers: #{suppliers.count}"

# ---------------------------------------------------------------------------
# Product categories & brands
# ---------------------------------------------------------------------------
categories = {}
[ "Hair Care", "Skin Care", "Tools & Equipment", "Consumables" ].each do |name|
  categories[name] = ProductCategory.find_or_create_by!(business: business, name: name)
end

brands = {}
[ "L'Oréal", "Schwarzkopf", "Wella", "Generic" ].each do |name|
  brands[name] = Brand.find_or_create_by!(business: business, name: name)
end
puts "Categories: #{categories.size}, Brands: #{brands.size}"

# ---------------------------------------------------------------------------
# Products
# ---------------------------------------------------------------------------
products_data = [
  { sku: "HC-DB-100", name: "Hair Color — Dark Brown",       cat: "Hair Care",          brand: "L'Oréal",     supplier: sup_gulf,      cost: 100, low: 20, reorder: 50, markup: 40, barcode: "6281000000100" },
  { sku: "HC-BL-101", name: "Hair Color — Blonde",           cat: "Hair Care",          brand: "Schwarzkopf", supplier: sup_gulf,      cost: 110, low: 20, reorder: 50, markup: 40, barcode: "6281000000101" },
  { sku: "SH-1L-200", name: "Shampoo 1L",                    cat: "Hair Care",          brand: "Wella",       supplier: sup_salam,     cost: 25,  low: 30, reorder: 80, markup: 50, barcode: "6281000000200" },
  { sku: "CN-1L-201", name: "Conditioner 1L",                cat: "Hair Care",          brand: "Wella",       supplier: sup_salam,     cost: 28,  low: 30, reorder: 80, markup: 50, barcode: "6281000000201" },
  { sku: "SK-FM-300", name: "Face Moisturizer",              cat: "Skin Care",          brand: "L'Oréal",     supplier: sup_cosmetics, cost: 45,  low: 15, reorder: 40, markup: 60, barcode: "6281000000300" },
  { sku: "SK-FC-301", name: "Facial Cleanser",               cat: "Skin Care",          brand: "L'Oréal",     supplier: sup_cosmetics, cost: 35,  low: 15, reorder: 40, markup: 60, barcode: "6281000000301" },
  { sku: "TL-HD-400", name: "Hair Dryer Pro",                cat: "Tools & Equipment",  brand: "Generic",     supplier: sup_salam,     cost: 180, low: 5,  reorder: 10, markup: 35, barcode: "6281000000400" },
  { sku: "TL-SS-401", name: "Styling Scissors",              cat: "Tools & Equipment",  brand: "Generic",     supplier: sup_salam,     cost: 90,  low: 5,  reorder: 15, markup: 35, barcode: "6281000000401" },
  { sku: "CS-DT-500", name: "Disposable Towels (100pk)",     cat: "Consumables",        brand: "Generic",     supplier: sup_gulf,      cost: 40,  low: 25, reorder: 60, markup: 30, barcode: "6281000000500" },
  { sku: "CS-LG-501", name: "Latex Gloves (100pk)",          cat: "Consumables",        brand: "Generic",     supplier: sup_gulf,      cost: 22,  low: 25, reorder: 60, markup: 30, barcode: "6281000000501" }
]

products = products_data.map do |d|
  Product.find_or_create_by!(business: business, sku: d[:sku]) do |p|
    p.name                      = d[:name]
    p.product_category          = categories[d[:cat]]
    p.brand                     = brands[d[:brand]]
    p.default_supplier          = d[:supplier]
    p.barcode                   = d[:barcode]
    p.initial_cost_price        = d[:cost]
    p.average_cost_price        = d[:cost]   # blended forward once stock is posted
    p.low_stock_level           = d[:low]
    p.reorder_quantity          = d[:reorder]
    p.selling_markup_percentage = d[:markup]
  end
end
prod = products.index_by(&:sku)
puts "Products: #{products.count}"

# ---------------------------------------------------------------------------
# Per-warehouse overrides — the Jeddah warehouse alerts earlier on fast movers.
# ---------------------------------------------------------------------------
{ "HC-DB-100" => { low: 10, reorder: 25 },
  "SH-1L-200" => { low: 15, reorder: 40 } }.each do |sku, cfg|
  ProductWarehouseSetting.find_or_create_by!(product: prod[sku], warehouse: w_jeddah) do |s|
    s.low_stock_level  = cfg[:low]
    s.reorder_quantity = cfg[:reorder]
  end
end
puts "Product warehouse settings: #{ProductWarehouseSetting.joins(:product).where(products: { business_id: business.id }).count}"

# ---------------------------------------------------------------------------
# Stock movements — posted through the real services, fresh-DB only.
# ---------------------------------------------------------------------------
if business.inventory_movements.none?
  # -- Posting helpers ------------------------------------------------------
  post_adjustment = lambda do |warehouse:, on:, reason:, lines:, note:|
    adj = business.stock_adjustments.build(
      warehouse: warehouse, adjusted_on: on, reason: reason, created_by: admin, notes: note
    )
    lines.each { |product, diff, unit_cost| adj.items.build(product: product, quantity_difference: diff, unit_cost: unit_cost) }
    result = Inventory::AdjustmentPoster.new(adj).call
    raise "Adjustment seed failed (#{reason} @ #{warehouse.name}): #{adj.errors.full_messages.join('; ')}" unless result.ok?
    adj
  end

  post_receipt = lambda do |warehouse:, supplier:, on:, lines:|
    grn = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: on, created_by: admin)
    lines.each { |product, qty, unit_cost| grn.items.build(product: product, quantity: qty, unit_cost: unit_cost) }
    result = Inventory::GoodsReceiptPoster.new(grn).call
    raise "Goods receipt seed failed (@ #{warehouse.name}): #{grn.errors.full_messages.join('; ')}" unless result.ok?
    grn
  end

  post_transfer = lambda do |from:, to:, on:, lines:|
    trf = business.stock_transfers.build(source_warehouse: from, destination_warehouse: to, transferred_on: on, created_by: admin)
    lines.each { |product, qty| trf.items.build(product: product, quantity: qty) }
    result = Inventory::StockTransferPoster.new(trf).call
    raise "Transfer seed failed (#{from.name} → #{to.name}): #{trf.errors.full_messages.join('; ')}" unless result.ok?
    trf
  end

  post_issue = lambda do |warehouse:, on:, note:, lines:|
    iss = business.stock_issues.build(warehouse: warehouse, issued_on: on, notes: note, created_by: admin)
    lines.each { |product, qty| iss.items.build(product: product, quantity: qty) }
    result = Inventory::StockIssuePoster.new(iss).call
    raise "Stock issue seed failed (@ #{warehouse.name}): #{iss.errors.full_messages.join('; ')}" unless result.ok?
    iss
  end

  # -- 1. Opening balances: establish on-hand + average cost per warehouse --
  opening = {
    w_central => 300,   # bulk distribution centre
    w_main    => 100,   # Riyadh salon floor stockroom
    w_jeddah  => 60     # Jeddah branch
  }
  opening.each do |warehouse, qty|
    post_adjustment.call(
      warehouse: warehouse,
      on:        60.days.ago.to_date,
      reason:    :opening_balance,
      note:      "Opening balance — initial stock take",
      lines:     products.map { |p| [ p, qty, p.initial_cost_price ] }
    )
  end

  # -- 2. Goods receipts: replenish the DC/main at varying cost (moves the avg) --
  post_receipt.call(warehouse: w_central, supplier: sup_gulf, on: 25.days.ago.to_date, lines: [
    [ prod["HC-DB-100"], 50, 120 ],
    [ prod["HC-BL-101"], 50, 125 ]
  ])
  post_receipt.call(warehouse: w_central, supplier: sup_salam, on: 20.days.ago.to_date, lines: [
    [ prod["SH-1L-200"], 100, 27 ],
    [ prod["CN-1L-201"], 100, 30 ],
    [ prod["CS-DT-500"], 80,  42 ]
  ])
  post_receipt.call(warehouse: w_main, supplier: sup_cosmetics, on: 15.days.ago.to_date, lines: [
    [ prod["SK-FM-300"], 40, 48 ],
    [ prod["SK-FC-301"], 40, 37 ]
  ])

  # -- 3. Transfers: move stock from the DC out to the two branches ---------
  post_transfer.call(from: w_central, to: w_main, on: 12.days.ago.to_date, lines: [
    [ prod["HC-DB-100"], 30 ], [ prod["HC-BL-101"], 30 ], [ prod["SH-1L-200"], 40 ]
  ])
  post_transfer.call(from: w_central, to: w_jeddah, on: 10.days.ago.to_date, lines: [
    [ prod["HC-DB-100"], 20 ], [ prod["SH-1L-200"], 25 ],
    [ prod["CS-DT-500"], 20 ], [ prod["CS-LG-501"], 20 ]
  ])

  # -- 4. Stock issues: consumption on the salon floor ---------------------
  post_issue.call(warehouse: w_main, on: 7.days.ago.to_date, note: "Salon floor usage — Riyadh", lines: [
    [ prod["HC-DB-100"], 12 ], [ prod["SH-1L-200"], 15 ], [ prod["SK-FM-300"], 8 ]
  ])
  post_issue.call(warehouse: w_jeddah, on: 5.days.ago.to_date, note: "Salon floor usage — Jeddah", lines: [
    [ prod["HC-DB-100"], 8 ], [ prod["CS-DT-500"], 10 ]
  ])

  # -- 5. Adjustments: damage / loss corrections ---------------------------
  post_adjustment.call(warehouse: w_jeddah, on: 3.days.ago.to_date, reason: :damaged,
                       note: "Water-damaged stock discarded",
                       lines: [ [ prod["CS-DT-500"], -5, 0 ] ])
  post_adjustment.call(warehouse: w_main, on: 2.days.ago.to_date, reason: :manual_correction,
                       note: "Cycle-count correction",
                       lines: [ [ prod["SK-FC-301"], -3, 0 ] ])

  # -- 6. Stock count sessions across the workflow --------------------------
  # A session preloads a row for every product (system quantity snapshotted),
  # then counted quantities are entered (plan = small, realistic variances).
  # partial: true leaves products outside the plan uncounted (blank) — to show the
  # in-progress progress bar / filters; otherwise every product is counted.
  build_count = lambda do |warehouse:, on:, counter:, plan:, notes:, partial: false|
    count = business.stock_counts.build(warehouse: warehouse, counted_on: on, created_by: counter, notes: notes)
    business.products.ordered.each do |product|
      system_qt = product.stock_in(warehouse)
      counted =
        if plan.key?(product.sku) then [ system_qt + plan[product.sku], 0 ].max
        elsif partial             then nil                 # left uncounted
        else system_qt
        end
      count.items.build(product: product, system_quantity: system_qt, counted_quantity: counted)
    end
    count.save!
    count.start_counting!(counter)   # draft → in_progress
    count
  end

  # (a) Approved — runs through approval, generating a real stock-count adjustment.
  approved_count = build_count.call(warehouse: w_main, on: 1.day.ago.to_date, counter: mgr_riyadh,
                                    plan: { "HC-DB-100" => -2, "SH-1L-200" => +3, "SK-FM-300" => 0 },
                                    notes: "Monthly physical count — Riyadh")
  approved_count.mark_completed!(mgr_riyadh)
  approve_result = Inventory::StockCountApprover.new(approved_count, user: admin).call
  raise "Stock count approval seed failed: #{approved_count.errors.full_messages.join('; ')}" unless approve_result.ok?

  # (b) Completed — counted and submitted, awaiting approval.
  completed_count = build_count.call(warehouse: w_jeddah, on: Date.current, counter: mgr_jeddah,
                                     plan: { "SH-1L-200" => -1 }, notes: "Weekly count — Jeddah")
  completed_count.mark_completed!(mgr_jeddah)

  # (c) In progress — counting underway, most products still uncounted.
  build_count.call(warehouse: w_central, on: Date.current, counter: admin,
                   plan: { "HC-DB-100" => +1 }, notes: "Spot count — Central DC", partial: true)

  puts "Inventory documents posted: " \
       "#{GoodsReceipt.for_business(business).count} receipts, " \
       "#{StockTransfer.for_business(business).count} transfers, " \
       "#{StockIssue.for_business(business).count} issues, " \
       "#{StockAdjustment.for_business(business).count} adjustments, " \
       "#{StockCount.for_business(business).count} counts"
else
  puts "Inventory movements already present — skipping document posting (idempotent)"
end

puts "Inventory ledger: #{business.inventory_movements.count} movements; " \
     "total stock value SAR #{products.sum(&:stock_value).round(2)}"

# ===========================================================================
# PERFORMANCE EVALUATION
# ---------------------------------------------------------------------------
# Department-scoped evaluation templates and their criteria are reference data,
# seeded idempotently. Departments are matched case/space-insensitively (mirror-
# ing Department's own name normalization) so an existing department — e.g. one
# backfilled from the legacy users.department string — is reused rather than
# duplicated. Criteria are populated only when a template is first created, so
# manual edits made in the UI are never overwritten on a re-seed. No sample
# reviews, scores, or observations are created.
# ===========================================================================

# Reuse an existing department by its normalized (trimmed, case-insensitive)
# name, or create it. Never creates a near-duplicate of a department that
# already exists under a different case or spacing.
def seed_department(business, name)
  normalized = name.to_s.strip.gsub(/\s+/, " ")
  Department.where(business: business)
            .where("lower(name) = ?", normalized.downcase)
            .first_or_create!(name: normalized)
end

# Default evaluation templates per department, each with its ordered criteria.
performance_defaults = {
  "Hair Stylists" => {
    template: "Hair Stylist Evaluation",
    criteria: [
      [ "Uniform & Personal Hygiene", "Clean, professional appearance and grooming" ],
      [ "Punctuality",                "Arrives on time and ready for each shift" ],
      [ "Customer Service",           "Warmth, attentiveness, and client rapport" ],
      [ "Service Quality",            "Technical quality and consistency of work" ],
      [ "Service Speed",              "Efficiency without sacrificing quality" ]
    ]
  },
  "Reception" => {
    template: "Reception Evaluation",
    criteria: [
      [ "Booking Accuracy",         "Correct appointments, no double-booking" ],
      [ "Customer Service",         "Friendly, helpful front-desk experience" ],
      [ "Communication Skills",     "Clear phone and in-person communication" ],
      [ "Attendance & Punctuality", "Reliable presence at the desk" ],
      [ "Teamwork",                 "Coordinates well with stylists and managers" ]
    ]
  },
  "Warehouse" => {
    template: "Warehouse Evaluation",
    criteria: [
      [ "Inventory Accuracy", "Counts and records match physical stock" ],
      [ "Organization",       "Tidy, well-labelled, navigable storage" ],
      [ "Process Compliance", "Follows receiving, issuing, and count procedures" ],
      [ "Stock Monitoring",   "Flags low stock and discrepancies promptly" ]
    ]
  }
}

performance_defaults.each do |dept_name, config|
  department = seed_department(business, dept_name)

  template = EvaluationTemplate.find_or_initialize_by(
    business: business, department: department, name: config[:template]
  )

  # Criteria are seeded only on the template's first creation (initial seed),
  # so re-running never duplicates or resurrects criteria edited away in the UI.
  if template.new_record?
    template.active = true
    template.save!
    config[:criteria].each_with_index do |(name, description), index|
      template.evaluation_criteria.create!(
        name: name, description: description, sort_order: index
      )
    end
  end
end

criteria_count = EvaluationCriterion
  .joins(:evaluation_template)
  .where(evaluation_templates: { business_id: business.id }).count
puts "Performance: #{Department.where(business: business).count} departments, " \
     "#{EvaluationTemplate.for_business(business).count} templates, #{criteria_count} criteria " \
     "(no reviews/observations seeded)"

# ---------------------------------------------------------------------------
# Permission Roles — two optional demo roles to illustrate the system.
# The business owner creates and names their own roles in the UI;
# nothing here is required or enforced by the application.
# ---------------------------------------------------------------------------
[
  {
    name:        "Full Access",
    description: "Example: can manage everything except business settings",
    permissions: %w[
      view_employees manage_employees manage_salary_profiles
      view_attendance manage_attendance manage_devices
      view_payroll view_payroll_analytics view_payroll_audit_log
      create_payroll regenerate_payroll submit_payroll_review
      complete_branch_review approve_payroll_items
      finalize_payroll pay_payroll reopen_payroll delete_payroll
      manage_adjustments approve_adjustments
      view_requests approve_requests
      view_shifts manage_shifts assign_shifts
      view_reports export_reports
      view_inventory manage_inventory view_inventory_reports
      manage_suppliers manage_products manage_stock_receipts
      manage_stock_issues manage_stock_transfers
      manage_stock_counts post_stock_counts view_stock_count_reports
      view_performance manage_evaluation_templates create_observations
      manage_reviews finalize_reviews
    ],
    permission_scopes: {
      "view_employees"   => "business_wide",
      "manage_employees" => "business_wide",
      "manage_salary_profiles" => "business_wide",
      "view_attendance"  => "business_wide",
      "manage_attendance" => "business_wide",
      "view_payroll"     => "business_wide",
      "complete_branch_review" => "business_wide",
      "manage_adjustments" => "business_wide",
      "view_requests"    => "business_wide",
      "approve_requests" => "business_wide",
      "view_shifts"      => "business_wide",
      "assign_shifts"    => "business_wide"
    }
  },
  {
    name:        "View Only",
    description: "Example: read-only access across all modules",
    permissions: %w[
      view_employees view_attendance view_payroll
      view_requests view_shifts view_reports
      view_performance
    ],
    permission_scopes: {
      "view_employees"  => "business_wide",
      "view_attendance" => "business_wide",
      "view_payroll"    => "business_wide",
      "view_requests"   => "business_wide",
      "view_shifts"     => "business_wide"
    }
  }
].each do |attrs|
  PermissionRole.find_or_create_by!(business: business, name: attrs[:name]) do |r|
    r.description      = attrs[:description]
    r.permissions      = attrs[:permissions]
    r.permission_scopes = attrs[:permission_scopes]
  end
end
puts "Permission roles: #{PermissionRole.where(business: business).count} roles (owner can rename/delete/add freely)"

# ---------------------------------------------------------------------------
# Payment Methods
# ---------------------------------------------------------------------------
[
  { name: "Cash",      name_ar: "نقداً",           settlement_type: "cash",    supports_refunds: true,  position: 0 },
  { name: "Visa",      name_ar: "فيزا",            settlement_type: "card",    supports_refunds: true,  position: 1 },
  { name: "Instapay",  name_ar: "إنستاباي",        settlement_type: "ewallet", supports_refunds: false, position: 2 },
  { name: "Gift Card", name_ar: "بطاقة هدية",      settlement_type: "voucher", supports_refunds: false, position: 3 }
].each_with_index do |attrs, _|
  PaymentMethod.find_or_initialize_by(business: business, name: attrs[:name]).tap do |pm|
    pm.assign_attributes(attrs)
    pm.active = true
    pm.save!
  end
end
puts "Payment methods: #{PaymentMethod.for_business(business).count} configured"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts "\n== Seed Complete =="
puts "  Business  : #{business.name}"
puts "  Branches  : #{Branch.where(business: business).count}"
puts "  Users     : #{business.users.count} (owner: #{business.owner&.full_name}, #{business.users.count - 1} staff)"
puts "  Records   : #{AttendanceRecord.joins(:branch).where(branches: { business: business }).count} attendance records"
puts "  Requests  : #{EmployeeRequest.for_business(business).count} employee requests"
puts "  Payroll   : #{PayrollPeriod.where(business: business).count} periods, #{PayrollEntry.joins(:payroll_period).where(payroll_periods: { business: business }).count} entries"
puts "  Inventory : #{Warehouse.for_business(business).count} warehouses, #{Product.for_business(business).count} products, #{business.inventory_movements.count} movements"
puts "  Performance: #{Department.where(business: business).count} departments, #{EvaluationTemplate.for_business(business).count} templates, #{EvaluationCriterion.joins(:evaluation_template).where(evaluation_templates: { business_id: business.id }).count} criteria"
puts "  Payment Methods: #{PaymentMethod.for_business(business).count}"
puts "\n  Credentials (password: password123)"
puts "    admin@workpulse.dev          — Owner"
puts "    area.manager@workpulse.dev   — Area Manager (all branches)"
puts "    accountant@workpulse.dev     — Staff"
puts "    manager.riyadh@workpulse.dev — Branch Manager (Riyadh)"
puts "    manager.jeddah@workpulse.dev — Branch Manager (Jeddah)"
puts "    ahmed.hassan@workpulse.dev   — Employee (Riyadh, monthly SAR 8,000)"
puts "    fatima.ali@workpulse.dev     — Employee (Riyadh, monthly SAR 7,500)"
puts "    omar.nasser@workpulse.dev    — Employee (Riyadh, daily SAR 350)"
puts "    layla.ibrahim@workpulse.dev  — Employee (Jeddah, monthly SAR 6,500)"
puts "    yusuf.karimi@workpulse.dev   — Employee (Jeddah, daily SAR 300)"
puts "    reem.sultan@workpulse.dev    — Employee (Jeddah, monthly SAR 7,000)"
puts ""
