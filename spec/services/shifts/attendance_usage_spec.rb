require "rails_helper"

# F2 — the Workforce read contract Shifts::AttendanceUsage. Behaviour through the
# model, policy, index and bulk delete stays pinned by
# spec/characterization/workforce/shift_assignment_attendance_usage_spec.rb.
RSpec.describe Shifts::AttendanceUsage do
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  let(:handler) { double("handler", recorded_against?: true, recorded_against_sql: "EXISTS(x = shift_assignments.id)") }

  it "lists its two operations and has the Attendance & Payroll implementation registered at boot" do
    expect(described_class::OPERATIONS).to eq(%i[recorded_against? recorded_against_sql])
    expect(described_class.handler).to equal(Attendance::ShiftAssignmentUsage)
  end

  it "rejects an incomplete handler, keeping the current one" do
    partial = Module.new { def self.recorded_against?(**) = true }
    with_handler(:current) do
      expect { described_class.register(partial) }.to raise_error(ArgumentError, /recorded_against_sql/)
      expect(described_class.handler).to eq(:current)
    end
  end

  it "raises NotRegistered when no handler is registered" do
    with_handler(nil) do
      expect { described_class.recorded_against?(assignment_id: 1) }.to raise_error(described_class::NotRegistered)
      expect { described_class.recorded_against_sql(assignment_column: "shift_assignments.id") }
        .to raise_error(described_class::NotRegistered)
    end
  end

  it "dispatches with the given arguments" do
    with_handler(handler) do
      expect(described_class.recorded_against?(assignment_id: 7)).to be(true)
      expect(described_class.recorded_against_sql(assignment_column: "shift_assignments.id"))
        .to eq("EXISTS(x = shift_assignments.id)")
    end
    expect(handler).to have_received(:recorded_against?).with(assignment_id: 7)
    expect(handler).to have_received(:recorded_against_sql).with(assignment_column: "shift_assignments.id")
  end

  it "refuses a non-boolean answer and SQL that is not correlated to the column" do
    with_handler(double("bad", recorded_against?: nil, recorded_against_sql: "TRUE")) do
      expect { described_class.recorded_against?(assignment_id: 1) }.to raise_error(ArgumentError, /true or false/)
      expect { described_class.recorded_against_sql(assignment_column: "shift_assignments.id") }
        .to raise_error(ArgumentError, /correlated/)
    end
  end

  it "accepts only a qualified column name (the only interpolated input)" do
    with_handler(handler) do
      [ "id", "shift_assignments.id; DROP TABLE x", "1=1", nil ].each do |column|
        expect { described_class.recorded_against_sql(assignment_column: column) }.to raise_error(ArgumentError, /qualified column/)
      end
    end
  end

  it "names nothing from Attendance & Payroll" do
    code = File.read(Rails.root.join("app/services/shifts/attendance_usage.rb")).lines.grep_v(/^\s*#/).join
    expect(code).not_to match(/\bAttendance(Record)?\b|Attendance::|attendance_records|Payroll/)
  end
end
