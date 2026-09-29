require "rails_helper"

RSpec.describe EmployeeDataRequests::Reviewer do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:manager)  { edr_manager(business: business) }
  let(:reviewer) { edr_reviewer(business: business) }
  let!(:managed_branch) do
    create(:branch, business: business).tap { |b| b.update_column(:branch_manager_id, manager.id) }
  end
  let(:request) do
    create(:employee_data_request, business: business, submitted_by: manager,
                                   national_id: "29501011234567", phone_number: "01001234567",
                                   manager_notes: "تم الاتفاق مع الموظف على 9000 جنيه + عمولة.")
  end

  describe ".approve" do
    subject(:result) { described_class.approve(request_id: request.id, actor: reviewer) }

    it "creates the employee with only the approved personal data" do
      request && reviewer
      expect { result }.to change(User, :count).by(1)
      expect(result).to be_ok

      employee = request.reload.employee
      expect(request).to be_approved
      expect(request.reviewed_by).to eq(reviewer)
      expect(employee).to have_attributes(
        business_id: business.id, first_name: "محمد", last_name: "أحمد علي حسن",
        identity_card_number: "29501011234567", phone_number: "01001234567",
        address: "15 شارع التحرير، الدقي، الجيزة", date_of_birth: Date.new(1995, 4, 12)
      )
      expect(employee.full_name).to eq("محمد أحمد علي حسن")
    end

    it "stores the ID photos on the employee's existing document attachments (as independent copies)" do
      result
      employee = request.reload.employee
      revision = request.revisions.last
      expect(employee.national_id_front).to be_attached
      expect(employee.national_id_back).to be_attached
      expect(employee.national_id_front.blob.id).not_to eq(revision.id_front.blob.id)
      expect(employee.national_id_front.download).to eq(revision.id_front.download)
    end

    it "does not create a salary profile even when the notes mention salary" do
      expect { result }.not_to change(SalaryProfile, :count)
      expect(request.reload.employee.salary_profiles).to be_empty
    end

    it "does not assign a branch (not even the manager's) or a shift" do
      expect { result }.not_to change(ShiftAssignment, :count)
      employee = request.reload.employee
      expect(employee.shift_assignments).to be_empty
      expect(Branch.where(branch_manager_id: employee.id).or(Branch.where(area_manager_id: employee.id))).to be_empty
      expect(employee.effective_branch_on(Date.current)).to be_nil
    end

    it "does not assign permissions or employment settings" do
      result
      employee = request.reload.employee
      expect(employee.permission_role_id).to be_nil
      expect(employee).to have_attributes(employment_type: nil, department_id: nil)
    end

    it "records the approval in the history and audit log" do
      result
      expect(request.events.reload.map(&:action)).to eq(%w[submitted approved])
      expect(AuditLog.where(auditable: request, action: "employee_data_request.approved").count).to eq(1)
      expect(AuditLog.where(auditable: request.reload.employee, action: "employee.created_from_data_request").count).to eq(1)
    end

    it "refuses when the national ID now belongs to an existing user, leaving the request pending" do
      request
      create(:user, business: business, identity_card_number: "29501011234567")
      expect(result).not_to be_ok
      expect(request.reload).to be_pending_review
    end

    it "refuses a request that is not pending review" do
      described_class.reject(request_id: request.id, actor: reviewer, note: "بيانات غير صحيحة")
      expect(result).not_to be_ok
    end
  end

  describe ".reject" do
    it "requires a reason" do
      result = described_class.reject(request_id: request.id, actor: reviewer, note: " ")
      expect(result).not_to be_ok
      expect(request.reload).to be_pending_review
    end

    it "rejects with a reason, preserving the submitted data" do
      result = described_class.reject(request_id: request.id, actor: reviewer, note: "الرقم القومي لا يطابق البطاقة")
      expect(result).to be_ok
      expect(request.reload).to be_rejected
      event = request.events.last
      expect(event).to have_attributes(action: "rejected", note: "الرقم القومي لا يطابق البطاقة", actor: reviewer)
      expect(request.revisions.first.national_id).to eq("29501011234567")
      expect(AuditLog.where(auditable: request, action: "employee_data_request.rejected").count).to eq(1)
      expect(request.employee).to be_nil
    end
  end

  describe ".request_changes" do
    it "sends the request back with the reviewer's note" do
      result = described_class.request_changes(request_id: request.id, actor: reviewer,
                                               note: "صورة البطاقة الخلفية غير واضحة، برجاء إعادة رفعها.")
      expect(result).to be_ok
      expect(request.reload).to be_changes_requested
      expect(request.latest_review_event.note).to eq("صورة البطاقة الخلفية غير واضحة، برجاء إعادة رفعها.")
    end
  end

  it "only finds requests in the actor's business" do
    other_reviewer = edr_reviewer(business: create(:business))
    expect { described_class.approve(request_id: request.id, actor: other_reviewer) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end

RSpec.describe EmployeeDataRequests::Reviewer, "corrections" do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:manager)  { edr_manager(business: business) }
  let(:reviewer) { edr_reviewer(business: business) }
  let(:request) do
    create(:employee_data_request, business: business, submitted_by: manager,
                                   national_id: "29504121234567", phone_number: "01001234567",
                                   job_title: "كوافير", manager_notes: "مرتب 9000 جنيه + عمولة")
  end

  describe ".correct" do
    it "appends a reviewer correction and keeps the manager's submission untouched" do
      result = described_class.correct(request_id: request.id, actor: reviewer,
                                       corrections: { job_title: "مديرة صالون", hire_date: "2026-11-01" })
      expect(result).to be_ok

      submission, correction = request.reload.revisions.to_a
      expect(submission).to have_attributes(source: "submission", job_title: "كوافير", hire_date: Date.new(2026, 10, 1))
      expect(correction).to have_attributes(source: "reviewer_correction", submitted_by: reviewer,
                                            job_title: "مديرة صالون", hire_date: Date.new(2026, 11, 1),
                                            manager_notes: "مرتب 9000 جنيه + عمولة")
      expect(correction.id_front.blob).to eq(submission.id_front.blob)
      expect(request).to be_pending_review
      expect(request.events.map(&:action)).to eq(%w[submitted corrected])

      audit = AuditLog.find_by(auditable: request, action: "employee_data_request.corrected")
      expect(audit.diff).to include(job_title: [ "كوافير", "مديرة صالون" ])
      expect(audit.metadata["changed_fields"]).to contain_exactly("job_title", "hire_date")
    end

    it "does nothing when no value changed" do
      described_class.correct(request_id: request.id, actor: reviewer, corrections: { job_title: "كوافير" })
      expect(request.reload.revisions.count).to eq(1)
      expect(request.events.map(&:action)).to eq(%w[submitted])
    end

    it "validates corrections with the same rules and saves nothing when invalid" do
      result = described_class.correct(request_id: request.id, actor: reviewer,
                                       corrections: { national_id: "123", emergency_contact_phone: "" })
      expect(result).not_to be_ok
      expect(result.record.errors.attribute_names).to include(:national_id, :emergency_contact_phone)
      expect(request.reload.revisions.count).to eq(1)
    end

    it "ignores attempts to change notes or employment configuration" do
      described_class.correct(request_id: request.id, actor: reviewer,
                              corrections: { job_title: "مديرة صالون", manager_notes: "x", branch_id: 1, salary: 1 })
      expect(request.reload.revisions.last.manager_notes).to eq("مرتب 9000 جنيه + عمولة")
    end
  end

  describe ".approve with corrections" do
    it "creates the employee from the corrected values without any further input" do
      result = described_class.approve(request_id: request.id, actor: reviewer,
                                       corrections: { job_title: "ريسبشن", identity_card_expiry_date: "2032-01-31" })
      expect(result).to be_ok

      employee = request.reload.employee
      expect(employee).to have_attributes(
        first_name: "محمد", last_name: "أحمد علي حسن", identity_card_number: "29504121234567",
        phone_number: "01001234567", address: "15 شارع التحرير، الدقي، الجيزة", date_of_birth: Date.new(1995, 4, 12),
        identity_card_expiry_date: Date.new(2032, 1, 31), job_title: "ريسبشن", hire_date: Date.new(2026, 10, 1),
        emergency_contact_name: "فاطمة حسن", emergency_contact_phone: "01229876543",
        emergency_contact_relationship: "والدة"
      )
      expect(employee.national_id_front).to be_attached
      expect(employee.national_id_back).to be_attached
      expect(employee.permission_role_id).to be_nil
      expect(employee.salary_profiles).to be_empty
      expect(employee.shift_assignments).to be_empty
      expect(request.events.map(&:action)).to eq(%w[submitted corrected approved])
    end

    %i[hire_date identity_card_expiry_date].each do |field|
      it "refuses to approve when the reviewer clears #{field}" do
        result = described_class.approve(request_id: request.id, actor: reviewer, corrections: { field => "" })
        expect(result).not_to be_ok
        expect(result.record.errors.of_kind?(field, :blank)).to be(true)
        expect(request.reload).to be_pending_review
        expect(request.employee).to be_nil
      end

      it "refuses to approve an older request whose version is missing #{field}" do
        request.revisions.first.update_column(field, nil)
        result = described_class.approve(request_id: request.id, actor: reviewer)
        expect(result).not_to be_ok
        expect(result.record.errors.of_kind?(field, :blank)).to be(true)
        expect(request.reload.employee).to be_nil
      end
    end

    it "transfers the approved hire date and ID expiry to the employee" do
      described_class.approve(request_id: request.id, actor: reviewer,
                              corrections: { hire_date: "2026-12-01", identity_card_expiry_date: "2033-03-15" })
      expect(request.reload.employee).to have_attributes(hire_date: Date.new(2026, 12, 1),
                                                         identity_card_expiry_date: Date.new(2033, 3, 15))
    end

    it "approves with the address cleared by the reviewer" do
      result = described_class.approve(request_id: request.id, actor: reviewer, corrections: { address: "" })
      expect(result).to be_ok
      expect(request.reload.employee.address).to be_nil
    end

    it "rejects a corrected job title outside the managed list" do
      result = described_class.approve(request_id: request.id, actor: reviewer, corrections: { job_title: "وظيفة مخترعة" })
      expect(result).not_to be_ok
      expect(result.record.errors.of_kind?(:job_title, :not_in_list)).to be(true)
      expect(request.reload.employee).to be_nil
    end

    it "is all-or-nothing: a refused approval also discards the corrections" do
      create(:user, business: create(:business), phone_number: "01111111111")
      result = described_class.approve(request_id: request.id, actor: reviewer,
                                       corrections: { phone_number: "01111111111" })
      expect(result).not_to be_ok
      expect(request.reload).to be_pending_review
      expect(request.revisions.count).to eq(1)
      expect(request.employee).to be_nil
    end
  end
end
