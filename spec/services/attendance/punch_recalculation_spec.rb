require "rails_helper"

# Punches from every source — mobile (CheckInService / CheckOutService) and the
# biometric device (PunchService) — are evidence for their work date, and the
# record is a pure function of that set (Attendance::PunchAggregator): the
# check-in is the earliest punch, the check-out the latest (when the day has a
# departure), every derived value is re-derived from the pair, and the arrival
# order never matters. Regression for the Oct 31 2026 report: a device sync moved
# the check-in of a record closed from mobile, and worked minutes, early-leave
# minutes and the early_leave status stayed those of the old check-in.
RSpec.describe "Attendance punch aggregation and recalculation across sources" do
  let(:business) do
    create(:business, timezone: "Africa/Cairo", business_day_start_hour: 6, overtime_grace_minutes: 30)
  end
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) } # 09:00–17:00, overtime enabled
  let!(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 10, 1))
  end

  let(:work_date) { Date.new(2026, 10, 31) }

  def cairo(time) = ActiveSupport::TimeZone["Africa/Cairo"].parse(time)
  def at(time) = cairo("2026-10-31 #{time}")

  def mobile_check_in(time, user: employee, latitude: nil, longitude: nil)
    travel_to(time) { Attendance::CheckInService.call(user: user, branch: branch, latitude: latitude, longitude: longitude) }
  end

  def mobile_check_out(time, user: employee, latitude: nil, longitude: nil)
    travel_to(time) { Attendance::CheckOutService.call(user: user, branch: branch, latitude: latitude, longitude: longitude) }
  end

  def device_punch(time, user: employee)
    Attendance::PunchService.call(employee: user, punched_at: time, business: business)
  end

  # Events: [:device, time] | [:mobile_in, time] | [:mobile_out, time]
  def deliver(event)
    kind, time = event
    case kind
    when :device     then device_punch(time)
    when :mobile_in  then mobile_check_in(time, latitude: "30.0444", longitude: "31.2357")
    when :mobile_out then mobile_check_out(time, latitude: "30.05", longitude: "31.24")
    end
  end

  def reset!
    BiometricPunchLog.where(employee: employee).delete_all
    AttendanceAdjustment.where(attendance_record: AttendanceRecord.where(user: employee)).delete_all
    AttendanceRecord.where(user: employee).delete_all
  end

  def record(date = work_date) = AttendanceRecord.find_by!(user: employee, work_date: date)

  STATE = %w[
    check_in_at check_out_at check_in_source check_out_source
    check_in_latitude check_in_longitude check_out_latitude check_out_longitude
    late_minutes early_leave_minutes worked_minutes overtime_minutes status
  ].freeze

  def state(rec = record) = rec.reload.attributes.slice(*STATE)

  # Every derived value equals a recomputation from scratch of the current pair.
  def expect_no_stale_values(rec = record)
    rec.reload
    expected = rec.attributes.slice(*STATE)
    rec.assign_attributes(late_minutes: 7, early_leave_minutes: 7, worked_minutes: 7, overtime_minutes: 7, status: "absent")
    Attendance::DerivedFields.apply!(rec, mobile_grace: true)
    expect(rec.attributes.slice(*STATE)).to eq(expected)
  end

  def results_for(orders)
    orders.map do |order|
      reset!
      order.each do |event|
        deliver(event)
        expect_no_stale_values if AttendanceRecord.exists?(user: employee, work_date: work_date)
      end
      state
    end
  end

  describe "every arrival order of the same punch set gives the same record" do
    it "device-only, five punches: all 120 orders agree" do
      punches = %w[08:52:00 09:05:00 12:30:00 13:10:00 17:20:00].map { |t| [ :device, at(t) ] }

      results = results_for(punches.permutation.to_a)

      expect(results.uniq.size).to eq(1)
      expect(results.first).to include(
        "check_in_at" => at("08:52:00"), "check_out_at" => at("17:20:00"),
        "check_in_source" => "biometric_device", "check_out_source" => "biometric_device",
        "late_minutes" => 0, "early_leave_minutes" => 0, "worked_minutes" => 508, "status" => "present"
      )
    end

    it "mixed sources, the device wins both ends: every interleaving of the syncs with the mobile punches agrees" do
      mobile_in = [ :mobile_in, at("09:10:00") ] # always first: a mobile check-in needs no record yet
      rest      = [ [ :device, at("08:52:00") ], [ :device, at("09:30:00") ],
                    [ :mobile_out, at("16:40:00") ], [ :device, at("17:15:00") ] ]

      results = results_for(rest.permutation.map { |order| [ mobile_in, *order ] })

      expect(results.uniq.size).to eq(1)
      expect(results.first).to include(
        "check_in_at" => at("08:52:00"), "check_in_source" => "biometric_device",
        "check_in_latitude" => nil, "check_in_longitude" => nil,
        "check_out_at" => at("17:15:00"), "check_out_source" => "biometric_device",
        "check_out_latitude" => nil, "check_out_longitude" => nil,
        "late_minutes" => 0, "early_leave_minutes" => 0, "worked_minutes" => 503, "status" => "present"
      )
    end

    it "mixed sources, mobile wins both ends: the mobile punches and their coordinates are kept in every order" do
      mobile_in = [ :mobile_in, at("08:50:00") ]
      rest      = [ [ :device, at("09:00:00") ], [ :device, at("13:00:00") ],
                    [ :device, at("16:30:00") ], [ :mobile_out, at("17:05:00") ] ]

      results = results_for(rest.permutation.map { |order| [ mobile_in, *order ] })

      expect(results.uniq.size).to eq(1)
      expect(results.first).to include(
        "check_in_at" => at("08:50:00"), "check_in_source" => "mobile",
        "check_in_latitude" => BigDecimal("30.0444"), "check_out_at" => at("17:05:00"),
        "check_out_source" => "mobile", "check_out_latitude" => BigDecimal("30.05"), "status" => "present"
      )
    end

    it "three or more punches near the start: no check-out in any order, then one in every order once a departure exists" do
      entry = %w[09:00:00 09:20:00 09:45:00].map { |t| [ :device, at(t) ] }

      open_days = results_for(entry.permutation.to_a)
      expect(open_days.uniq.size).to eq(1)
      expect(open_days.first).to include("check_in_at" => at("09:00:00"), "check_out_at" => nil,
                                         "worked_minutes" => nil, "status" => "incomplete")

      closed_days = results_for((entry + [ [ :device, at("10:05:00") ] ]).permutation.to_a)
      expect(closed_days.uniq.size).to eq(1)
      expect(closed_days.first).to include("check_in_at" => at("09:00:00"), "check_out_at" => at("10:05:00"),
                                           "worked_minutes" => 65, "status" => "early_leave")
    end

    it "an explicit mobile check-out is a departure even within the gap, in every order" do
      mobile_in = [ :mobile_in, at("09:00:00") ]
      rest      = [ [ :device, at("09:10:00") ], [ :mobile_out, at("09:40:00") ], [ :device, at("09:50:00") ] ]

      results = results_for(rest.permutation.map { |order| [ mobile_in, *order ] })

      expect(results.uniq.size).to eq(1)
      expect(results.first).to include("check_in_at" => at("09:00:00"), "check_out_at" => at("09:50:00"),
                                       "check_out_source" => "biometric_device", "worked_minutes" => 50)
    end

    it "redelivering the whole set is idempotent: same record, no punch has an effect" do
      punches = [ [ :device, at("08:55:00") ], [ :device, at("12:00:00") ], [ :device, at("17:10:00") ] ]
      punches.each { |e| deliver(e) }
      before = state

      results = punches.map { |e| deliver(e) }

      expect(results.map(&:action).uniq).to eq([ "rejected_spam" ])
      expect(state).to eq(before)
    end
  end

  describe "mobile and device punches are treated equally" do
    it "mobile check-in, then an earlier device punch synced later → the device punch is the check-in" do
      mobile_check_in(at("09:20:00"), latitude: "30.0444", longitude: "31.2357")
      expect(record).to have_attributes(late_minutes: 20, status: "late")

      result = device_punch(at("08:55:00"))

      expect(result.action).to eq("check_in_updated")
      expect(record.reload).to have_attributes(
        check_in_at: at("08:55:00"), check_in_source: "biometric_device", check_in_latitude: nil,
        late_minutes: 0, status: "incomplete", check_out_at: nil, worked_minutes: nil
      )
    end

    it "mobile check-in, then a later device punch at the entrance → recorded, the mobile check-in stays" do
      mobile_check_in(at("09:00:00"))

      result = device_punch(at("09:25:00"))

      expect(result.action).to eq("recorded")
      expect(result.log.attendance_record).to eq(record)
      expect(record.reload).to have_attributes(check_in_at: at("09:00:00"), check_in_source: "mobile", check_out_at: nil)
    end

    it "device check-in, then a mobile check-in → refused (API contract), the device check-in stays" do
      device_punch(at("08:55:00"))

      expect(mobile_check_in(at("09:10:00"))).not_to be_success
      expect(record.reload).to have_attributes(check_in_at: at("08:55:00"), check_in_source: "biometric_device")
    end

    it "a late mobile check-in followed by an earlier device check-in → the mobile punch is the check-out" do
      mobile_check_in(at("17:00:00"), latitude: "30.0444", longitude: "31.2357")

      device_punch(at("09:00:00"))

      expect(record.reload).to have_attributes(
        check_in_at: at("09:00:00"), check_in_source: "biometric_device", check_in_latitude: nil,
        check_out_at: at("17:00:00"), check_out_source: "mobile", check_out_latitude: BigDecimal("30.0444"),
        worked_minutes: 480, status: "present"
      )
    end

    it "mobile check-out, then a later device punch → the device punch is the check-out, the early leave is gone" do
      mobile_check_in(at("09:00:00"))
      mobile_check_out(at("15:00:00"), latitude: "30.05", longitude: "31.24")
      expect(record).to have_attributes(early_leave_minutes: 120, status: "early_leave")

      expect(device_punch(at("17:00:00")).action).to eq("check_out")
      expect(record.reload).to have_attributes(
        check_out_at: at("17:00:00"), check_out_source: "biometric_device",
        check_out_latitude: nil, check_out_longitude: nil,
        worked_minutes: 480, early_leave_minutes: 0, overtime_minutes: 0, status: "present"
      )
    end

    it "device check-out, then a later mobile check-out → the mobile check-out replaces it" do
      device_punch(at("09:00:00"))
      device_punch(at("15:00:00"))

      expect(mobile_check_out(at("17:00:00"), latitude: "30.05", longitude: "31.24")).to be_success
      expect(record.reload).to have_attributes(
        check_out_at: at("17:00:00"), check_out_source: "mobile", check_out_latitude: BigDecimal("30.05"),
        worked_minutes: 480, early_leave_minutes: 0, status: "present"
      )
    end

    it "device check-out, then an earlier mobile check-out (device clock ahead) → recorded, the later device check-out stays" do
      device_punch(at("09:00:00"))
      device_punch(at("17:00:00"))

      expect(mobile_check_out(at("16:58:00"))).to be_success
      expect(record.reload).to have_attributes(check_out_at: at("17:00:00"), check_out_source: "biometric_device")
      expect(BiometricPunchLog.where(employee: employee, source: "mobile").pluck(:action)).to eq([ "recorded" ])
    end
  end

  describe "the reported Oct 31 record (hour-based 12-hour shift)" do
    let(:shift) { create(:shift, :hour_based, business: business, required_hours: 12, overtime_rate_multiplier: 1.0) }

    # Mobile check-in and check-out 5 seconds apart at 00:38 on Nov 1 (work date
    # Oct 31, the day starting at 06:00), then the device's 11:03 check-in arrives.
    before do
      mobile_check_in(cairo("2026-11-01 00:38:13"))
      mobile_check_out(cairo("2026-11-01 00:38:18"))
    end

    it "starts as an early departure of the whole shift (the explicit check-out counts despite the 5 seconds)" do
      expect(record).to have_attributes(worked_minutes: 0, early_leave_minutes: 720, status: "early_leave")
    end

    it "drops the early departure once the device check-in is synced" do
      expect(device_punch(at("11:03:12")).action).to eq("check_in_updated")
      expect(record.reload).to have_attributes(
        check_in_at: at("11:03:12"), check_in_source: "biometric_device",
        check_out_at: cairo("2026-11-01 00:38:18"), check_out_source: "mobile",
        worked_minutes: 815, early_leave_minutes: 0, overtime_minutes: 95, status: "overtime"
      )
      expect_no_stale_values
    end
  end

  describe "work-period boundaries" do
    it "punches on adjacent business days never merge, whatever the arrival order across both days" do
      day1 = [ at("09:00:00"), at("17:00:00"), cairo("2026-11-01 05:59:00") ]                              # 05:59 → still Oct 31
      day2 = [ cairo("2026-11-01 06:00:00"), cairo("2026-11-01 09:10:00"), cairo("2026-11-01 17:00:00") ] # from 06:00 → Nov 1

      results = (day1 + day2).permutation.first(120).map do |order|
        reset!
        order.each { |time| device_punch(time) }
        [ state(record(work_date)), state(record(work_date + 1)) ]
      end

      expect(results.uniq.size).to eq(1)
      oct31, nov1 = results.first
      expect(oct31).to include("check_in_at" => at("09:00:00"), "check_out_at" => cairo("2026-11-01 05:59:00"))
      expect(nov1).to include("check_in_at" => cairo("2026-11-01 06:00:00"), "check_out_at" => cairo("2026-11-01 17:00:00"))
    end

    context "with an overnight shift (13:00–01:00)" do
      let(:shift) { create(:shift, :overnight, business: business) }

      it "aggregates the after-midnight punches into the previous work date in every order" do
        mobile_in = [ :mobile_in, at("13:10:00") ]
        rest      = [ [ :mobile_out, cairo("2026-11-01 00:30:00") ], [ :device, at("12:55:00") ],
                      [ :device, cairo("2026-11-01 01:05:00") ] ]

        results = results_for(rest.permutation.map { |order| [ mobile_in, *order ] })

        expect(results.uniq.size).to eq(1)
        expect(results.first).to include(
          "check_in_at" => at("12:55:00"), "check_out_at" => cairo("2026-11-01 01:05:00"),
          "late_minutes" => 0, "early_leave_minutes" => 0, "worked_minutes" => 730, "status" => "present"
        )
        expect(AttendanceRecord.where(user: employee).pluck(:work_date)).to eq([ work_date ])
      end
    end

    it "a mobile check-out after the boundary closes the previous work date's open record" do
      mobile_check_in(at("20:00:00"))

      expect(mobile_check_out(cairo("2026-11-01 06:30:00"))).to be_success # past 06:00: work date Nov 1
      expect(record).to have_attributes(check_out_at: cairo("2026-11-01 06:30:00"))
      expect(BiometricPunchLog.where(employee: employee, source: "mobile").pluck(:work_date).uniq).to eq([ work_date ])
    end

    it "a mobile check-out never closes an open record older than the previous work date" do
      mobile_check_in(at("20:00:00"))

      expect(mobile_check_out(cairo("2026-11-02 18:00:00"))).not_to be_success
      expect(record.reload.check_out_at).to be_nil
    end

    it "each work date uses its own assigned shift" do
      hour_based = create(:shift, :hour_based, business: business, required_hours: 8)
      assignment.update!(effective_to: work_date)
      create(:shift_assignment, user: employee, branch: branch, shift: hour_based, effective_from: work_date + 1)

      [ at("09:30:00"), at("16:00:00"), cairo("2026-11-01 09:30:00"), cairo("2026-11-01 16:00:00") ].reverse_each { |t| device_punch(t) }

      expect(record(work_date)).to have_attributes(late_minutes: 30, early_leave_minutes: 60, status: "late_early_leave")
      expect(record(work_date + 1)).to have_attributes(late_minutes: 0, early_leave_minutes: 90, status: "early_leave")
    end

    it "never mixes two employees' punches" do
      colleague = create(:user, business: business)
      create(:shift_assignment, user: colleague, branch: branch, shift: shift, effective_from: Date.new(2026, 10, 1))

      device_punch(at("08:00:00"), user: colleague)
      device_punch(at("09:00:00"))
      device_punch(at("19:00:00"), user: colleague)
      device_punch(at("17:00:00"))

      expect(record).to have_attributes(check_in_at: at("09:00:00"), check_out_at: at("17:00:00"))
      expect(AttendanceRecord.find_by!(user: colleague)).to have_attributes(check_in_at: at("08:00:00"),
                                                                            check_out_at: at("19:00:00"))
    end

    it "a delayed sync days later re-derives its own work date and touches no other" do
      mobile_check_in(at("09:20:00"))
      mobile_check_out(at("15:00:00"))
      mobile_check_in(cairo("2026-11-03 09:00:00"))
      later_day = state(record(Date.new(2026, 11, 3)))

      travel_to(cairo("2026-11-03 12:00:00")) do
        device_punch(at("08:58:00"))
        device_punch(at("17:05:00"))
      end

      expect(record).to have_attributes(check_in_at: at("08:58:00"), check_out_at: at("17:05:00"),
                                        late_minutes: 0, early_leave_minutes: 0, status: "present")
      expect(state(record(Date.new(2026, 11, 3)))).to eq(later_day)
    end
  end

  describe "manual values are pinned" do
    let(:manager) { create(:user, business: business) }

    def adjust(**times)
      Attendance::AdjustmentService.call(record: record, adjusted_by: manager,
                                         params: times.transform_values(&:iso8601).merge(reason: "manager correction"))
    end

    it "a check-in corrected by a manager is not replaced by a later-synced device punch; the punch stays auditable" do
      mobile_check_in(at("09:20:00"))
      mobile_check_out(at("17:00:00"))
      adjust(check_in_at: at("09:00:00"))

      result = device_punch(at("08:40:00"))

      expect(result.action).to eq("recorded")
      expect(record.reload).to have_attributes(check_in_at: at("09:00:00"), check_in_source: "admin_manual",
                                               check_out_at: at("17:00:00"))
      expect(record.biometric_punch_logs.where(action: "recorded").pluck(:punched_at, :source))
        .to eq([ [ at("08:40:00"), "biometric" ] ])
      expect(record.attendance_adjustments.pluck(:field_name)).to eq([ "check_in_at" ])
    end

    it "a check-out corrected by a manager stays, in every order of the later punches" do
      results = [ at("18:30:00"), at("16:00:00") ].permutation.map do |order|
        reset!
        device_punch(at("09:00:00"))
        device_punch(at("15:00:00"))
        adjust(check_out_at: at("17:00:00"))
        order.each { |t| expect(device_punch(t).action).to eq("recorded") }
        expect(record.biometric_punch_logs.where(action: "recorded").count).to eq(2)
        state
      end

      expect(results.uniq.size).to eq(1)
      expect(results.first).to include("check_out_at" => at("17:00:00"), "check_out_source" => "admin_manual")
    end
  end

  describe "historical (pre-change) duplicate logs" do
    # Before this change every duplicate was logged rejected_spam WITHOUT a record
    # and never took part in a calculation (3,318 such logs in production). They
    # are not evidence, so a new punch on that day cannot move it by them.
    def historical_duplicate(time)
      create(:biometric_punch_log, business: business, employee: employee, work_date: work_date,
                                   action: "rejected_spam", source: "biometric", attendance_record: nil,
                                   punched_at: time, received_at: time + 2.minutes)
    end

    it "a new punch leaves the day as it was, around duplicates seconds before the check-in and after the check-out" do
      device_punch(at("09:00:30"))
      device_punch(at("17:00:00"))
      historical_duplicate(at("09:00:00"))
      historical_duplicate(at("17:00:40"))
      before = state

      expect(device_punch(at("12:00:00")).action).to eq("recorded")
      expect(state).to eq(before)
    end

    it "cannot change a late-arrival penalty: a 09:14:50 duplicate does not replace a 09:15:10 check-in" do
      create(:penalty_rule, shift: shift, rule_type: "late_arrival",
             deduction_type: "fixed_amount", threshold_minutes: 15, deduction_value: 50)
      create(:salary_profile, :monthly, user: employee, base_amount: 8_000.0, effective_from: Date.new(2026, 1, 1))
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 10, working_days: 26)
      device_punch(at("09:15:10"))
      device_punch(at("17:00:00"))
      historical_duplicate(at("09:14:50")) # counted, it would make the lateness 14 minutes: under the threshold

      device_punch(at("12:00:00"))

      expect(record.reload).to have_attributes(check_in_at: at("09:15:10"), late_minutes: 15, status: "late")
      items = Payroll::EntryCalculator.call(period: period, user: employee, business: business)
                                      .payroll_line_items.where(item_type: "late_penalty")
      expect(items.map(&:original_minutes)).to eq([ 15 ])
    end

    it "a duplicate logged under the new rule is linked and counts, deterministically" do
      results = [ [ at("09:00:30"), at("09:00:00") ], [ at("09:00:00"), at("09:00:30") ] ].map do |order|
        reset!
        order.each { |t| device_punch(t) }
        device_punch(at("17:00:00"))
        state
      end

      expect(results.uniq.size).to eq(1)
      expect(results.first["check_in_at"]).to eq(at("09:00:00"))
      expect(BiometricPunchLog.where(employee: employee, action: "rejected_spam").pluck(:attendance_record_id)).to all(eq(record.id))
    end
  end

  describe "rule-profile grace is preserved per source (not changed by this fix)" do
    let(:profile) do
      create(:shift_rule_profile, business: business, late_grace_minutes: 10, early_leave_grace_minutes: 10)
    end
    let!(:assignment) do
      create(:shift_assignment, user: employee, branch: branch, shift: shift, rule_profile: profile,
                                effective_from: Date.new(2026, 10, 1))
    end

    it "mobile check-in and check-out get the grace, as CheckInService / CheckOutService always did" do
      mobile_check_in(at("09:08:00"))
      mobile_check_out(at("16:55:00"))

      expect(record.reload).to have_attributes(late_minutes: 0, early_leave_minutes: 0, status: "present")
    end

    it "device punches do not, as PunchService never did" do
      device_punch(at("09:08:00"))
      device_punch(at("16:55:00"))

      expect(record.reload).to have_attributes(late_minutes: 8, early_leave_minutes: 5, status: "late_early_leave")
    end

    it "a mixed day applies it to the mobile field only, in every arrival order" do
      results = [ [ :device, at("16:55:00") ], [ :device, at("16:30:00") ] ].permutation.map do |order|
        reset!
        [ [ :mobile_in, at("09:08:00") ], *order ].each { |e| deliver(e) }
        state
      end

      expect(results.uniq.size).to eq(1)
      expect(results.first).to include("check_in_source" => "mobile", "late_minutes" => 0,
                                       "check_out_source" => "biometric_device", "early_leave_minutes" => 5)
    end

    it "switches with the effective punch: an earlier device check-in synced later loses the mobile grace" do
      mobile_check_in(at("09:08:00"))
      expect(record).to have_attributes(late_minutes: 0)

      device_punch(at("09:06:00"))

      expect(record.reload).to have_attributes(check_in_source: "biometric_device", late_minutes: 6)
    end

    it "a manager edit recomputes without grace, as AdjustmentService always did" do
      mobile_check_in(at("09:08:00"))
      mobile_check_out(at("16:55:00"))

      Attendance::AdjustmentService.call(record: record, adjusted_by: create(:user, business: business),
                                         params: { check_out_at: at("16:50:00").iso8601, reason: "left earlier" })

      expect(record.reload).to have_attributes(late_minutes: 8, early_leave_minutes: 10)
    end

    context "with expected work hours on an hour-based shift" do
      let(:shift)   { create(:shift, :hour_based, business: business, required_hours: 8) }
      let(:profile) { create(:shift_rule_profile, :ramadan, business: business) } # 6 h expected, 10 min grace

      it "a mobile check-out measures the shortfall against the profile, a device check-out against the shift" do
        mobile_check_in(at("09:00:00"))
        mobile_check_out(at("15:00:00"))
        expect(record.reload).to have_attributes(worked_minutes: 360, early_leave_minutes: 0)

        reset!
        device_punch(at("09:00:00"))
        device_punch(at("15:00:00"))
        expect(record.reload).to have_attributes(worked_minutes: 360, early_leave_minutes: 120)
      end
    end
  end

  describe "location metadata follows the effective punch" do
    it "keeps a replaced mobile punch's coordinates in its own punch log" do
      mobile_check_in(at("09:20:00"), latitude: "30.0444", longitude: "31.2357")
      device_punch(at("08:55:00"))

      log = BiometricPunchLog.find_by!(employee: employee, source: "mobile")
      expect(JSON.parse(log.raw_payload)).to include("direction" => "check_in", "latitude" => "30.0444", "longitude" => "31.2357")
      expect(log.punched_at).to eq(at("09:20:00"))
      expect(record.reload).to have_attributes(check_in_latitude: nil, check_in_longitude: nil)
    end

    it "logs an unlogged (pre-change) mobile punch with its coordinates before a device punch replaces it" do
      legacy = create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                          work_date: work_date, date: work_date,
                                          check_in_at: at("09:00:00"), check_in_source: "mobile",
                                          check_out_at: at("15:00:00"), check_out_source: "mobile",
                                          check_out_latitude: 30.05, check_out_longitude: 31.24)

      device_punch(at("17:00:00"))

      reconstructed = BiometricPunchLog.find_by!(employee: employee, source: "mobile", action: "recorded")
      expect(reconstructed.punched_at).to eq(at("15:00:00"))
      expect(JSON.parse(reconstructed.raw_payload)).to include("reconstructed_from_record" => true,
                                                               "direction" => "check_out", "latitude" => "30.05")
      expect(legacy.reload).to have_attributes(check_out_at: at("17:00:00"), check_out_latitude: nil,
                                               check_in_at: at("09:00:00"), status: "present")
    end
  end

  describe "missing check-out" do
    it "a second device punch within the gap is recorded and does not become a check-out" do
      device_punch(at("09:00:00"))

      expect(device_punch(at("09:40:00")).action).to eq("recorded")
      expect(record.reload).to have_attributes(check_out_at: nil, worked_minutes: nil, status: "incomplete")
    end
  end

  describe "early-leave permissions and penalties after a re-derivation" do
    let(:period) do
      create(:payroll_period, business: business, period_year: 2026, period_month: 10, working_days: 26)
    end

    before do
      create(:salary_profile, :monthly, user: employee, base_amount: 8_000.0, effective_from: Date.new(2026, 1, 1))
      create(:penalty_rule, shift: shift, rule_type: "early_leave",
             deduction_type: "fixed_amount", threshold_minutes: 30, deduction_value: 50)
      period

      # Mobile day 09:00–15:00 (120 min early); the device's 16:00 punch synced afterwards.
      mobile_check_in(at("09:00:00"))
      mobile_check_out(at("15:00:00"))
      device_punch(at("16:00:00"))
    end

    def penalty_items
      Payroll::EntryCalculator.call(period: period, user: employee, business: business)
                              .payroll_line_items.where(item_type: "early_leave_penalty")
    end

    it "penalizes the re-derived 60 minutes, net of a partially covering approved permission" do
      create(:employee_request, :early_leave, :approved, user: employee, requested_for_date: work_date,
                                                           duration_minutes: 30)

      expect(record.reload).to have_attributes(early_leave_minutes: 60, status: "early_leave")
      expect(penalty_items.map { |i| [ i.original_minutes, i.permission_minutes ] }).to eq([ [ 60, 30 ] ])
    end

    it "removes the penalty when an approved permission covers the re-derived minutes" do
      create(:employee_request, :early_leave, :approved, user: employee, requested_for_date: work_date,
                                                           duration_minutes: 60)

      expect(penalty_items).to be_empty
    end

    it "ignores a pending permission" do
      create(:employee_request, :early_leave, user: employee, requested_for_date: work_date, duration_minutes: 60)

      expect(penalty_items.size).to eq(1)
    end

    it "does not duplicate the penalty when the same punches are synced again" do
      device_punch(at("16:00:00"))
      device_punch(at("09:00:00"))

      expect(penalty_items.size).to eq(1)
      expect(record.reload.early_leave_minutes).to eq(60)
    end
  end
end
