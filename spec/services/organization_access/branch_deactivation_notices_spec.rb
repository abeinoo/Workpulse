require "rails_helper"

# BUG-029 — the Organization & Access contract the deactivation dialog asks for
# what other domains still record at a branch. Several providers, registered
# together as one ordered list.
RSpec.describe OrganizationAccess::BranchDeactivationNotices do
  let(:registered) { described_class.providers }
  let(:branch)     { create(:branch) }

  before { registered } # remember the boot-time providers before any example replaces them

  after { described_class.register(*registered) }

  def provider_returning(value)
    Module.new { define_singleton_method(:notices_for) { |branch:| value } }
  end

  def notice(title)
    described_class::Notice.new(title: title, summary: "S", lines: [ described_class::Line.new(label: "L", value: 3) ])
  end

  it "is wired at boot to the Laundry and the Attendance providers, in that order" do
    expect(registered).to eq([ Laundry::BranchDeactivationNotice, Attendance::BranchDeactivationNotice ])
  end

  it "refuses to register a provider that does not implement notices_for" do
    expect { described_class.register(provider_returning([]), Module.new) }.to raise_error(ArgumentError, /notices_for/)
  end

  it "refuses an empty list and a provider listed twice" do
    provider = provider_returning([])

    expect { described_class.register }.to raise_error(ArgumentError, /at least one/)
    expect { described_class.register(provider, provider) }.to raise_error(ArgumentError, /more than once/)
  end

  it "keeps the registered list when a new list is refused" do
    expect { described_class.register(provider_returning([]), Module.new) }.to raise_error(ArgumentError)

    expect(described_class.providers).to eq(registered)
  end

  it "replaces the list on every registration, so re-registering (a code reload) never accumulates providers" do
    first  = provider_returning([ notice("first") ])
    second = provider_returning([ notice("second") ])

    described_class.register(first, second)
    described_class.register(first, second)

    expect(described_class.providers).to eq([ first, second ])
    expect(described_class.notices_for(branch: branch).map(&:title)).to eq(%w[first second])

    described_class.register(second)
    expect(described_class.providers).to eq([ second ])
  end

  it "raises when no provider is registered, never silently showing nothing" do
    described_class.instance_variable_set(:@providers, nil)

    expect { described_class.notices_for(branch: branch) }.to raise_error(described_class::NotRegistered)
  end

  it "returns every provider's notices in registration order" do
    described_class.register(provider_returning([ notice("A1"), notice("A2") ]), provider_returning([]),
                             provider_returning([ notice("C") ]))

    expect(described_class.notices_for(branch: branch).map(&:title)).to eq(%w[A1 A2 C])
  end

  it "accepts no notices" do
    described_class.register(provider_returning([]))

    expect(described_class.notices_for(branch: branch)).to eq([])
  end

  it "rejects anything that is not domain-neutral notice data, from any provider" do
    [ nil, [ { title: "T" } ], [ described_class::Notice.new(title: "T", lines: [ described_class::Line.new(label: "L", value: "3") ]) ] ]
      .each do |value|
        described_class.register(provider_returning([ notice("fine") ]), provider_returning(value))
        expect { described_class.notices_for(branch: branch) }.to raise_error(ArgumentError), value.inspect
      end
  end
end
