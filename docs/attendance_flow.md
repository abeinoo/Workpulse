# Attendance Flow — Source of Truth

## Overview

All attendance data enters through one of five sources, passes through centralised
parsing and calculation services, and is persisted as `AttendanceRecord` rows with
pre-computed penalty/overtime metrics. Views and APIs never re-derive these values.

---

## 1. Timezone Strategy

**Rule**: All timestamps are stored as UTC in the database. Every conversion for
display or calculation goes through the business's IANA timezone
(`Business#timezone_object` → `ActiveSupport::TimeZone`).

**How it's set at request time**: `ApplicationController` runs
`around_action :set_business_timezone` for authenticated requests, which calls
`Time.use_zone(business.timezone_object)`. This means `Time.current`, `Time.zone`,
and bare `in_time_zone` calls (without an explicit zone argument) all use the
business timezone for the duration of the request.

**Display helpers** (in `ApplicationHelper`):
```
local_time(value)           → "14:30"
local_datetime(value)       → "Jun 5, 2026 14:30"
local_date(value)           → "Jun 5, 2026"
local_short_date(value)     → "5 Jun"
local_datetime_input(value) → "2026-06-05T14:30"  (for datetime-local inputs)
```
All helpers use `current_business_timezone` (memoised as `@_biz_tz`). **Never call
`.strftime` directly on a datetime column** — always go through these helpers.

---

## 2. Timestamp Parsing — `Attendance::TimestampParser`

**Source of truth**: `app/services/attendance/timestamp_parser.rb`

Different entry points deliver timestamps with different timezone semantics:

| Source           | Timestamp form                    | Parsing strategy                        |
|------------------|-----------------------------------|-----------------------------------------|
| `mobile`         | `Time.current` (UTC, no string)   | No parsing needed; already a UTC object |
| `biometric_device` | ISO 8601 with offset OR bare local | With offset → respect offset; bare → business TZ |
| `import`         | Bare local datetime string        | Business TZ assumed                     |
| `admin_manual`   | Bare local datetime string        | Business TZ assumed                     |
| `api`            | ISO 8601 with or without offset   | With offset → respect; bare → business TZ |

**Output**: Always a `ActiveSupport::TimeWithZone` normalised to UTC for DB storage.

**Rule**: Any code that parses an incoming attendance timestamp **must** call
`Attendance::TimestampParser.parse(value, source: ..., business: ...)`. Direct use
of `Time.parse`, `DateTime.parse`, `Date.parse`, or `Time.zone.parse` outside this
service is prohibited for attendance timestamps.

---

## 3. Entry Points

### 3a. Mobile Check-In — `Attendance::CheckInService`
```
API POST /api/v1/attendance/check_in
  → CheckInService.call(user:, branch:, latitude:, longitude:)
    → GeolocationValidator — radius check vs branch
    → BusinessDay.work_date_for(check_in_at, user, branch) — resolves work_date
    → AttendanceRecord.create! with check_in_source: "mobile"
    → TimeCalculator.late_minutes(shift, check_in_at, branch)
```

### 3b. Mobile Check-Out — `Attendance::CheckOutService`
```
API POST /api/v1/attendance/check_out
  → CheckOutService.call(user:, branch:, latitude:, longitude:)
    → Finds open record (check_out_at: nil)
    → worked_minutes = (now - check_in_at) / 60
    → TimeCalculator.early_leave_minutes(shift, now, worked_mins, branch)
    → TimeCalculator.derive_status(late_minutes, early_leave_mins)
    → AttendanceRecord.update! with check_out_source: "mobile"
```

### 3c. Biometric Punch — `Attendance::PunchService`
```
API POST /api/v1/punches (BiometricBaseController — device-token auth)
  → PunchService.call(device:, timestamp_str:, employee_code:)
    → TimestampParser.parse(timestamp_str, source: :biometric_device, business:)
    → Determines check_in or check_out based on open record presence
    → Same late/early-leave/worked calculation as CheckInService / CheckOutService
    → check_in_source / check_out_source: "biometric_device"
    → BiometricPunchLog.create! for audit trail regardless of outcome
```

### 3d. CSV Import — `Attendance::CsvImporter`
```
Admin: POST /admin/attendance_imports
  → CsvImporter.call(file:, business:, branch:, imported_by:)
    → Parses CSV rows; timestamps via TimestampParser(source: :import)
    → BusinessDay.work_date_for for each row
    → Creates/updates AttendanceRecord rows in a transaction
    → AttendanceImportLog.create! with row-level errors
```

### 3e. Admin Manual Edit — `Attendance::AdjustmentService`
```
Web: PATCH /attendance_records/:id
  → AdjustmentService.call(record:, adjusted_by:, params:)
    → TimestampParser.parse(params[:check_in_at], source: :admin_manual, business:)
    → Recalculates worked_minutes, late_minutes, early_leave_minutes, status
    → AttendanceAdjustment.create! for audit trail
```

---

## 4. Time Calculation — `Attendance::TimeCalculator`

**Source of truth**: `app/services/attendance/time_calculator.rb`

```ruby
TimeCalculator.late_minutes(shift, check_in_at, branch)
  # shift.fixed_time? only; compares local check-in time vs shift.start_time in business TZ
  # Returns minutes late (≥0), or 0 for hour-based shifts

TimeCalculator.early_leave_minutes(shift, check_out_at, worked_minutes, branch)
  # fixed_time? → local checkout vs shift.end_time; handles overnight shifts (shift_end += 1.day)
  # hour_based? → required_hours * 60 - worked_minutes
  # Returns minutes early (≥0)

TimeCalculator.derive_status(late_minutes, early_leave_minutes)
  # → "late" | "early_leave" | "present"
```

**`worked_minutes`** is always computed as `((checkout_utc - checkin_utc) / 60).to_i` —
pure elapsed seconds, correct across all timezones, DST transitions, and midnight boundaries.

---

## 5. Overnight / Cross-Midnight Handling

**Definition**: An overnight shift has `check_out_at` (in business TZ) on a later calendar
date than `work_date`.

**Detection** (`AttendanceRecord#overnight?`):
```ruby
check_out_at.in_time_zone(tz).to_date > work_date
```
Uses the business timezone — not UTC — so a checkout at 23:30 UTC (= 02:30 next day in
Riyadh) correctly reports as overnight.

**SQL filter** (attendance index overnight toggle):
```sql
CAST(check_out_at AT TIME ZONE 'UTC' AT TIME ZONE <tz_name> AS date) > work_date
```

**Early-leave with overnight shifts** (`TimeCalculator.early_leave_minutes`):
The shift end is bumped `+1.day` when the checkout hour is past the shift start hour,
preventing a false "12-hour early leave" when the employee leaves at 01:00 on a 21:00–05:00 shift.

**`worked_minutes` across midnight**: Correct by construction — it's elapsed seconds regardless of
calendar date boundaries.

---

## 6. Anomaly Detection — `Attendance::AnomalyDetector`

**Source of truth**: `app/services/attendance/anomaly_detector.rb`

Runs post-hoc on a date range for a given user. Not called at punch time.
Called from:
- `OperationsDashboardController` (monthly window, batch per user)
- `Payroll::AnomalyDetector` (per payroll period)

Detectors:
1. `detect_repeated_lateness` — ≥3 late occurrences → `:warning`; ≥3 severe (≥30 min) → `:danger`
2. `detect_repeated_early_leave` — ≥3 early-leave occurrences
3. `detect_excessive_overtime` — weekly overtime hours > 10
4. `detect_suspicious_punches` — worked_minutes < 3 (possible swipe error)
5. `detect_missed_checkouts` — no check_out_at
6. `detect_outside_shift_window` — check-in > 60 min before/after shift start
7. `detect_biometric_mismatch` — mobile/biometric source inconsistency

Returns sorted `Anomaly` structs (danger < warning < info).

---

## 7. Payroll Deduction Pipeline

Penalties are **not** applied at check-in/out time. They are computed during payroll
generation by `Attendance::PenaltyCalculator`, which:

1. Receives the `AttendanceRecord`, the employee's daily rate, and optional permission overrides
2. Resolves the shift's `PenaltyRule` list for late_arrival / early_leave
3. Finds the applicable rule for the actual late/early minutes
4. Returns `late_penalty` and `early_leave_penalty` as SAR amounts

Permission offsets are applied first: if the employee has an approved `EmployeeRequest`
for `late_permission` or `early_leave` on the same date, the permitted minutes are
subtracted before looking up the penalty rule.

---

## 8. Export Consistency

CSV exports (`app/services/reports/`) only export `Date` objects and monetary amounts —
never raw datetime columns — so they contain no timezone ambiguity.

If future exports include check-in/out times they **must** use the business timezone:
```ruby
record.check_in_at.in_time_zone(business.timezone_object).strftime(...)
```

---

## 9. Notification Triggers

Attendance does not directly trigger notifications. Anomalies surfaced via
`OperationsDashboardController` are displayed in-app but do not create `Notification`
records (that is reserved for payroll workflow events).

---

## 10. Key Invariants

| Invariant | Enforcement |
|---|---|
| `work_date` is the business-TZ calendar date of the shift, not necessarily the UTC date of `check_in_at` | `BusinessDay.work_date_for` at creation |
| `worked_minutes` is always non-negative elapsed minutes | Computed as `(checkout - checkin) / 60` |
| `late_minutes` is 0 for hour-based shifts | `TimeCalculator.late_minutes` returns 0 for non-fixed-time |
| A record can only have one `work_date` per user | DB unique index + model validation |
| `check_in_source` / `check_out_source` is always one of `SOURCES` | `AttendanceRecord::SOURCES` constant + DB enum |
| All timestamps stored UTC, displayed in business TZ | `set_business_timezone` around_action + local_* helpers |
