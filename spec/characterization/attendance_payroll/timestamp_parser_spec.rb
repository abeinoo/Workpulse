require "rails_helper"

# Characterization (Milestone 2 Pilot 1, M1) — CURRENT Attendance::TimestampParser
# behaviour for inputs not pinned by spec/services/attendance/timestamp_parser_spec.rb
# (which covers offsets, zones, DST and blank/garbage input per source).
RSpec.describe "Characterization: Attendance::TimestampParser" do
  around { |example| travel_to(Time.zone.parse("2026-10-06 09:00:00 UTC")) { example.run } }

  let(:business) { create(:business, timezone: "Asia/Riyadh") }

  def parse(value, source: :biometric_device)
    Attendance::TimestampParser.parse(value, source: source, business: business)
  end

  it "returns the time in the business time zone" do
    expect(parse("2026-05-24T06:15:00Z").time_zone.name).to eq("Asia/Riyadh")
  end

  it "strips surrounding whitespace" do
    expect(parse("  2026-05-24 09:15:00  ").iso8601).to eq("2026-05-24T09:15:00+03:00")
  end

  it "respects a +HHMM offset without a colon and fractional seconds with Z" do
    expect(parse("2026-05-24T09:15:00+0100").iso8601).to eq("2026-05-24T11:15:00+03:00")
    expect(parse("2026-05-24T09:15:00.123Z").iso8601).to eq("2026-05-24T12:15:00+03:00")
  end

  it "reads a date alone as business-local midnight" do
    expect(parse("2026-05-24").iso8601).to eq("2026-05-24T00:00:00+03:00")
  end

  it "reads a time alone as that time today in the business zone" do
    expect(parse("09:15").iso8601).to eq("2026-10-06T09:15:00+03:00")
  end

  it "accepts slash-separated and day-first dates as business-local time" do
    expect(parse("2026/05/24 09:15").iso8601).to eq("2026-05-24T09:15:00+03:00")
    expect(parse("24-05-2026 09:15").iso8601).to eq("2026-05-24T09:15:00+03:00")
  end

  it "returns nil for epoch seconds and impossible dates" do
    expect(parse("1716541200")).to be_nil
    expect(parse("2026-13-45 09:00")).to be_nil
  end

  it "treats the api source and an unknown source like business-local time when no offset is given" do
    expect(parse("2026-05-24 09:15:00", source: :api).iso8601).to eq("2026-05-24T09:15:00+03:00")
    expect(parse("2026-05-24 09:15:00", source: :something_else).iso8601).to eq("2026-05-24T09:15:00+03:00")
  end

  it "accepts a non-string value by converting it with to_s" do
    expect(parse(Date.new(2026, 5, 24)).iso8601).to eq("2026-05-24T00:00:00+03:00")
  end
end
