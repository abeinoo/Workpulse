require "rails_helper"

RSpec.describe EmployeeDataRequests::Resubmitter do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:manager)  { edr_manager(business: business) }
  let(:reviewer) { edr_reviewer(business: business) }
  let(:request)  { create(:employee_data_request, business: business, submitted_by: manager, address: "عنوان قديم") }

  def send_back!
    EmployeeDataRequests::Reviewer.request_changes(request_id: request.id, actor: reviewer, note: "أعد رفع الخلفية")
  end

  def resubmit(actor: manager, **params)
    described_class.new(request_id: request.id, actor: actor, params: params).call
  end

  it "appends a new revision, keeps the original, and returns to pending review" do
    send_back!
    original = request.revisions.first
    result = resubmit(**edr_params(national_id: original.national_id, address: "عنوان جديد", id_front: nil))

    expect(result).to be_ok
    request.reload
    expect(request).to be_pending_review
    expect(request.revisions.map(&:revision_number)).to eq([ 1, 2 ])
    expect(request.revisions.first.address).to eq("عنوان قديم")
    latest = request.revisions.last
    expect(latest.address).to eq("عنوان جديد")
    # Front not re-uploaded → carried over; back re-uploaded → new blob.
    expect(latest.id_front.blob.id).to eq(original.id_front.blob.id)
    expect(latest.id_back.blob.id).not_to eq(original.id_back.blob.id)
    expect(latest.changed_fields_since(original)).to include(:address, :id_back)
    expect(request.events.map(&:action)).to eq(%w[submitted changes_requested resubmitted])
    audit = AuditLog.find_by(auditable: request, action: "employee_data_request.resubmitted")
    expect(audit.metadata["changed_fields"]).to include("address")
  end

  it "is only allowed after changes were requested" do
    result = resubmit(**edr_params)
    expect(result).not_to be_ok
    expect(request.reload.revisions.size).to eq(1)
  end

  it "is only allowed for the submitting manager" do
    send_back!
    other_manager = edr_manager(business: business)
    expect(resubmit(actor: other_manager, **edr_params)).not_to be_ok
  end
end
