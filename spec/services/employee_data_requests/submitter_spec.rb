require "rails_helper"

RSpec.describe EmployeeDataRequests::Submitter do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:manager)  { edr_manager(business: business) }

  def submit(**overrides)
    described_class.new(actor: manager, params: edr_params(**overrides)).call
  end

  it "creates a pending request with its first revision and a submitted event" do
    result = submit(manager_notes: "اتكلمت مع الموظف")

    expect(result).to be_ok
    request = result.record
    expect(request).to be_pending_review
    expect(request.submitted_by).to eq(manager)
    expect(request.revisions.size).to eq(1)
    revision = request.revisions.first
    expect(revision).to have_attributes(full_name: "محمد أحمد علي حسن", national_id: "29501011234567",
                                        manager_notes: "اتكلمت مع الموظف")
    expect(revision.id_front).to be_attached
    expect(revision.id_back).to be_attached
    expect(request.events.map(&:action)).to eq(%w[submitted])
    expect(AuditLog.where(auditable: request, action: "employee_data_request.submitted").count).to eq(1)
  end

  it "does not create or change any employee record before approval" do
    manager
    expect { submit }.not_to change(User, :count)
  end

  it "ignores branch / salary / permission params" do
    result = described_class.new(actor: manager,
                                 params: edr_params.merge(branch_id: 1, salary: 9000, permission_role_id: 1)).call
    expect(result).to be_ok
    expect(result.record).not_to respond_to(:branch_id)
  end

  it "returns the invalid revision (with errors) when a required field is missing" do
    result = submit(id_back: nil)
    expect(result).not_to be_ok
    expect(result.record.errors[:id_back]).to be_present
    expect(EmployeeDataRequest.count).to eq(0)
  end

  it "rejects a national ID already belonging to an employee" do
    create(:user, business: business, identity_card_number: "29501011234567")
    result = submit
    expect(result).not_to be_ok
    expect(result.record.errors[:national_id]).to be_present
  end

  it "rejects a second open request for the same national ID" do
    expect(submit).to be_ok
    result = submit(phone_number: "01009999999")
    expect(result).not_to be_ok
    expect(EmployeeDataRequest.count).to eq(1)
  end
end
