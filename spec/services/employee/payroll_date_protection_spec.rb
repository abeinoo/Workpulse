require "rails_helper"

# R3.2 G3: the Workforce contract Employee::PayrollDateProtection (OD-1). The
# wrapper fails closed and routes to whatever handler is registered — proven
# with a planted provider whose answers differ from the real data.
RSpec.describe Employee::PayrollDateProtection do
  let(:protected_answer) do
    described_class::Protected.new(starts_on: Date.new(2026, 9, 1), ends_on: Date.new(2026, 9, 30), stage: :in_review)
  end

  around do |example|
    registered = described_class.instance_variable_get(:@handler)
    example.run
  ensure
    described_class.instance_variable_set(:@handler, registered)
  end

  def provider(lock: nil, ranges: [])
    Module.new do
      define_singleton_method(:lock_protected_range) { |**| lock }
      define_singleton_method(:protected_ranges) { |**| ranges }
    end
  end

  def ask_lock = described_class.lock_protected_range(business_id: 1, from: Date.new(2026, 9, 1), through: Date.new(2026, 9, 30))
  def ask_ranges = described_class.protected_ranges(business_id: 1, from: Date.new(2026, 9, 1), through: Date.new(2026, 9, 30))

  it "is wired to the Attendance & Payroll implementation at boot" do
    expect(described_class.handler).to eq(Payroll::RequirementDateProtection)
  end

  it "refuses to register a handler that lacks an operation" do
    incomplete = Module.new { def self.lock_protected_range(**) = nil }
    expect { described_class.register(incomplete) }.to raise_error(ArgumentError, /protected_ranges/)
  end

  it "raises NotRegistered instead of skipping the check when no handler is registered" do
    described_class.instance_variable_set(:@handler, nil)
    expect { ask_lock }.to raise_error(described_class::NotRegistered)
    expect { ask_ranges }.to raise_error(described_class::NotRegistered)
  end

  it "routes both operations to the registered handler (planted provider)" do
    described_class.register(provider(lock: protected_answer, ranges: [ protected_answer ]))
    expect(ask_lock).to eq(protected_answer)
    expect(ask_ranges).to eq([ protected_answer ])

    described_class.register(provider(lock: nil, ranges: []))
    expect(ask_lock).to be_nil
    expect(ask_ranges).to eq([])
  end

  it "rejects an answer outside the contract (fails closed)" do
    described_class.register(provider(lock: protected_answer.with(stage: :under_review)))
    expect { ask_lock }.to raise_error(described_class::ContractViolation)

    described_class.register(provider(lock: "under_review"))
    expect { ask_lock }.to raise_error(described_class::ContractViolation)

    described_class.register(provider(ranges: nil))
    expect { ask_ranges }.to raise_error(described_class::ContractViolation)

    described_class.register(provider(ranges: [ protected_answer.with(starts_on: "2026-09-01") ]))
    expect { ask_ranges }.to raise_error(described_class::ContractViolation)
  end

  it "propagates a handler error" do
    failing = Module.new do
      def self.lock_protected_range(**) = raise(ActiveRecord::Deadlocked, "deadlock")
      def self.protected_ranges(**) = []
    end
    described_class.register(failing)
    expect { ask_lock }.to raise_error(ActiveRecord::Deadlocked)
  end
end
