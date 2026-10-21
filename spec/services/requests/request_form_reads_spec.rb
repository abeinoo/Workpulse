require "rails_helper"

# Batch V — request-validation reads (D-A5): the Workforce contract
# Requests::RequestFormReads, implemented by Payroll::RequestFormReads
# (spec/services/payroll/request_form_reads_spec.rb). The current behaviour of
# the seven read sites stays pinned by
# spec/characterization/workforce/request_validation_reads_spec.rb.
RSpec.describe Requests::RequestFormReads do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:viewer)   { create(:user, business: business) }

  let(:limit) do
    described_class::AdvanceLimit.new(description_key: "monthly_basis", max_amount: 3210.0, outstanding: 0.0,
                                      available: 3210.0, no_profile: false)
  end
  let(:day) do
    described_class::AttendanceDay.new(check_in_at: Time.zone.local(2026, 9, 18, 8), check_out_at: nil,
                                       status: "incomplete", worked_minutes: nil, duration_severity: nil)
  end

  # A handler answering every operation with the given results.
  def handler_with(**results)
    defaults = { advance_limit: limit, advance_limit_for: described_class::AdvanceLimitView.new(limit: limit, hidden: false),
                 salary_visible?: true, attendance_day: day, recent_check_ins: {}, duration_threshold_hours: 16 }
    double("handler", **defaults.merge(results))
  end

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  def call_each_operation
    {
      advance_limit:            -> { described_class.advance_limit(user: employee) },
      advance_limit_for:        -> { described_class.advance_limit_for(user: employee, viewer: viewer) },
      salary_visible?:          -> { described_class.salary_visible?(viewer: viewer, employee: employee) },
      attendance_day:           -> { described_class.attendance_day(user: employee, date: Date.new(2026, 9, 18)) },
      recent_check_ins:         -> { described_class.recent_check_ins(user: employee) },
      duration_threshold_hours: -> { described_class.duration_threshold_hours(severity: :critical, business: business) }
    }
  end

  describe "operations and value objects" do
    it "lists the six read operations" do
      expect(described_class::OPERATIONS).to eq(
        %i[advance_limit advance_limit_for salary_visible? attendance_day recent_check_ins duration_threshold_hours]
      )
    end

    it "keeps the 62-day inclusive check-in lookback" do
      expect(described_class::RECENT_CHECK_INS_DAYS).to eq(62)
    end

    it "AdvanceLimit carries exactly the fields Workforce reads, with no_profile?" do
      expect(described_class::AdvanceLimit.members).to eq(%i[description_key max_amount outstanding available no_profile])
      expect(described_class::AdvanceLimit.new(no_profile: true, available: 0.0)).to be_no_profile
      expect(described_class::AdvanceLimit.new(no_profile: nil)).not_to be_no_profile
    end

    it "AdvanceLimitView carries the limit and whether it is hidden" do
      expect(described_class::AdvanceLimitView.members).to eq(%i[limit hidden])
      expect(described_class::AdvanceLimitView.new(limit: nil, hidden: true)).to be_hidden
      expect(described_class::AdvanceLimitView.new(limit: nil, hidden: false)).not_to be_hidden
    end

    it "AttendanceDay carries exactly the five fields the request show page reads" do
      expect(described_class::AttendanceDay.members)
        .to eq(%i[check_in_at check_out_at status worked_minutes duration_severity])
    end
  end

  describe "registration" do
    it "has the Attendance & Payroll implementation registered at boot" do
      expect(described_class.handler).to equal(Payroll::RequestFormReads)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      partial = Module.new { def self.advance_limit(**) = nil }

      with_handler(:current) do
        expect { described_class.register(partial) }
          .to raise_error(ArgumentError, /advance_limit_for, salary_visible\?, attendance_day, recent_check_ins, duration_threshold_hours/)
        expect(described_class.handler).to eq(:current)
      end
    end

    it "accepts a complete handler" do
      handler = handler_with

      with_handler(nil) do
        described_class.register(handler)
        expect(described_class.handler).to equal(handler)
      end
    end

    it "raises NotRegistered for every operation when no handler is registered" do
      with_handler(nil) do
        call_each_operation.each do |operation, call|
          expect { call.call }.to raise_error(described_class::NotRegistered), operation.to_s
        end
      end
    end
  end

  describe "dispatch" do
    it "passes the arguments through and returns the handler's results unchanged" do
      view    = described_class::AdvanceLimitView.new(limit: limit, hidden: false)
      hint    = { "2026-09-18" => "2026-09-18T08:00" }
      handler = handler_with(advance_limit_for: view, recent_check_ins: hint, duration_threshold_hours: 24)

      with_handler(handler) do
        expect(described_class.advance_limit(user: employee)).to equal(limit)
        expect(described_class.advance_limit_for(user: employee, viewer: viewer)).to equal(view)
        expect(described_class.salary_visible?(viewer: viewer, employee: employee)).to be(true)
        expect(described_class.attendance_day(user: employee, date: Date.new(2026, 9, 18))).to equal(day)
        expect(described_class.recent_check_ins(user: employee)).to equal(hint)
        expect(described_class.duration_threshold_hours(severity: :critical, business: business)).to eq(24)
      end

      expect(handler).to have_received(:advance_limit).with(user: employee)
      expect(handler).to have_received(:advance_limit_for).with(user: employee, viewer: viewer)
      expect(handler).to have_received(:salary_visible?).with(viewer: viewer, employee: employee)
      expect(handler).to have_received(:attendance_day).with(user: employee, date: Date.new(2026, 9, 18))
      expect(handler).to have_received(:recent_check_ins).with(user: employee)
      expect(handler).to have_received(:duration_threshold_hours).with(severity: :critical, business: business)
    end

    it "accepts nil where the contract allows it (no limit configured, no attendance, a hidden limit)" do
      hidden = described_class::AdvanceLimitView.new(limit: nil, hidden: true)

      with_handler(handler_with(advance_limit: nil, attendance_day: nil, advance_limit_for: hidden)) do
        expect(described_class.advance_limit(user: employee)).to be_nil
        expect(described_class.attendance_day(user: employee, date: Date.new(2026, 9, 18))).to be_nil
        expect(described_class.advance_limit_for(user: employee, viewer: viewer)).to equal(hidden)
      end
    end

    it "rejects a result of the wrong type, naming the operation" do
      {
        advance_limit:            { advance_limit: { available: 1 } },
        advance_limit_for:        { advance_limit_for: nil },
        salary_visible?:          { salary_visible?: nil },
        attendance_day:           { attendance_day: Object.new },
        recent_check_ins:         { recent_check_ins: [] },
        duration_threshold_hours: { duration_threshold_hours: 16.0 }
      }.each do |operation, result|
        with_handler(handler_with(**result)) do
          expect { call_each_operation.fetch(operation).call }
            .to raise_error(ArgumentError, /\.#{Regexp.escape(operation.to_s)} returned/), operation.to_s
        end
      end
    end

    it "rejects an AdvanceLimitView whose limit is not an AdvanceLimit" do
      bad = described_class::AdvanceLimitView.new(limit: { available: 1 }, hidden: false)

      with_handler(handler_with(advance_limit_for: bad)) do
        expect { described_class.advance_limit_for(user: employee, viewer: viewer) }
          .to raise_error(ArgumentError, /advance_limit_for returned Hash/)
      end
    end

    it "propagates a handler error" do
      handler = handler_with
      allow(handler).to receive(:attendance_day).and_raise(ActiveRecord::StatementInvalid, "boom")

      with_handler(handler) do
        expect { described_class.attendance_day(user: employee, date: Date.new(2026, 9, 18)) }
          .to raise_error(ActiveRecord::StatementInvalid, "boom")
      end
    end
  end

  it "names nothing from Attendance & Payroll (code only, comments excluded)" do
    code = File.readlines(Rails.root.join("app/services/requests/request_form_reads.rb"))
               .reject { |line| line.lstrip.start_with?("#") }.join
    forbidden = /\bPayroll\b|\b(?:Attendance|Salary)::|\b(?:SalaryProfile|AttendanceRecord|PayrollPeriod|PayrollEntry|Advance)\b/
    expect(code.scan(forbidden)).to be_empty
  end
end
