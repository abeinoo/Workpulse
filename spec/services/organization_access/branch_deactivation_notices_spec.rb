require "rails_helper"

# BUG-029 — the Organization & Access contract the deactivation dialog asks for
# what other domains still record at a branch.
RSpec.describe OrganizationAccess::BranchDeactivationNotices do
  let(:registered) { described_class.provider }
  let(:branch)     { create(:branch) }

  after { described_class.register(registered) }

  def provider_returning(value)
    Module.new { define_singleton_method(:notices_for) { |branch:| value } }
  end

  before { registered } # remember the boot-time provider before any example replaces it

  it "is wired at boot to the Laundry provider" do
    expect(registered).to equal(Laundry::BranchDeactivationNotice)
  end

  it "refuses to register a provider that does not implement notices_for" do
    expect { described_class.register(Module.new) }.to raise_error(ArgumentError, /notices_for/)
  end

  it "raises when no provider is registered, never silently showing nothing" do
    described_class.instance_variable_set(:@provider, nil)

    expect { described_class.notices_for(branch: branch) }.to raise_error(described_class::NotRegistered)
  end

  it "passes the provider's notices through" do
    notice = described_class::Notice.new(title: "T", summary: "S",
                                         lines: [ described_class::Line.new(label: "L", value: 3) ])
    described_class.register(provider_returning([ notice ]))

    expect(described_class.notices_for(branch: branch)).to eq([ notice ])
  end

  it "accepts no notices" do
    described_class.register(provider_returning([]))

    expect(described_class.notices_for(branch: branch)).to eq([])
  end

  it "rejects anything that is not domain-neutral notice data" do
    [ nil, [ { title: "T" } ], [ described_class::Notice.new(title: "T", lines: [ described_class::Line.new(label: "L", value: "3") ]) ] ]
      .each do |value|
        described_class.register(provider_returning(value))
        expect { described_class.notices_for(branch: branch) }.to raise_error(ArgumentError), value.inspect
      end
  end
end
