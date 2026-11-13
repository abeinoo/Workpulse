require "rails_helper"

# R6: Scheduling::HolidayCalendar, the audited write path of the Holiday
# Calendar. Updates and deletes are fail-closed (log_audit!): the audit entry is
# the only record of the old values.
RSpec.describe Scheduling::HolidayCalendar do
  let(:business) { create(:business) }
  let(:hr)       { create(:user, business: business) }
  let(:calendar) { described_class.new(actor: hr) }

  def audits(action) = AuditLog.where(action: action)

  it "creates a holiday in the actor's business and audits date and kind" do
    result = calendar.create(date: "2026-07-23", name: "Revolution Day", kind: "public", business_id: create(:business).id)
    expect(result).to be_ok
    expect(result.record).to have_attributes(business_id: business.id, created_by_id: hr.id, date: Date.new(2026, 7, 23))
    expect(audits("holiday.created").sole.metadata).to include("date" => "2026-07-23", "kind" => "public", "name" => "Revolution Day")
  end

  it "refuses an invalid or duplicate holiday and writes nothing" do
    calendar.create(date: "2026-07-23", name: "Revolution Day", kind: "public")
    expect(calendar.create(date: "2026-07-23", name: "Again", kind: "company")).not_to be_ok
    expect(calendar.create(date: "", name: "No date", kind: "public")).not_to be_ok
    expect(Holiday.count).to eq(1)
    expect(audits("holiday.created").count).to eq(1)
  end

  it "updates a holiday and audits old and new values" do
    holiday = create(:holiday, created_by: hr, date: Date.new(2026, 7, 23), kind: "public", name: "Revolution Day")
    expect(calendar.update(holiday.id, kind: "company", name: "Company day")).to be_ok

    audit = audits("holiday.updated").sole
    expect(audit.diff).to include(kind: %w[public company], name: [ "Revolution Day", "Company day" ])
    expect(audit.metadata).to include("date" => "2026-07-23", "kind" => "public")
  end

  it "writes no audit entry for an update that changes nothing" do
    holiday = create(:holiday, created_by: hr)
    expect(calendar.update(holiday.id, name: holiday.name)).to be_ok
    expect(audits("holiday.updated")).to be_empty
  end

  it "deletes a holiday and keeps its values in the audit log" do
    holiday = create(:holiday, created_by: hr, date: Date.new(2026, 10, 6), name: "Armed Forces Day")
    expect(calendar.destroy(holiday.id)).to be_ok
    expect(Holiday.exists?(holiday.id)).to be(false)
    expect(audits("holiday.deleted").sole.metadata).to include("date" => "2026-10-06", "name" => "Armed Forces Day")
  end

  it "keeps the holiday when the audit entry of an update or delete cannot be written" do
    holiday = create(:holiday, created_by: hr, kind: "public")
    allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))

    expect(calendar.update(holiday.id, kind: "company")).to have_attributes(ok: false, error: :audit_failed)
    expect(calendar.destroy(holiday.id)).to have_attributes(ok: false, error: :audit_failed)
    expect(holiday.reload.kind).to eq("public")
  end

  it "never touches another business's holiday" do
    other = create(:holiday, created_by: create(:user, business: create(:business)))
    expect { calendar.update(other.id, name: "x") }.to raise_error(ActiveRecord::RecordNotFound)
    expect { calendar.destroy(other.id) }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
