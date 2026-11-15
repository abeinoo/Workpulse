require "rails_helper"

# R3.2 G5: the rollout switch reader (OD-2, OD-5) — off unless a start date is
# recorded and reached on the business day; R3.2 never writes it.
RSpec.describe Workforce::AttendanceRequirementRollout do
  let(:business) { create(:business, timezone: "Africa/Cairo", business_day_start_hour: 6) }

  def set(value) = business.update!(settings: (business.settings || {}).merge(described_class::SETTING => value))

  it "is off by default" do
    expect(described_class.active?(business)).to be(false)
    expect(described_class.enabled_on(business)).to be_nil
  end

  it "is on from the recorded date, compared with the business day" do
    set("2026-12-01")
    travel_to(Time.find_zone("Africa/Cairo").local(2026, 12, 1, 5, 59)) { expect(described_class.active?(business)).to be(false) }
    travel_to(Time.find_zone("Africa/Cairo").local(2026, 12, 1, 6, 0)) { expect(described_class.active?(business)).to be(true) }
  end

  it "treats an unreadable value as off" do
    set("soon")
    expect(described_class.active?(business)).to be(false)
  end

  it "is per business" do
    set("2026-01-01")
    expect(described_class.active?(create(:business))).to be(false)
  end

  it "is never written by application code" do
    writers = Dir[Rails.root.join("app/**/*.rb")].select { |path| File.read(path).include?("SETTING =>") }
    expect(writers).to be_empty
  end
end
