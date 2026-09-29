require "rails_helper"

# The employee form's job-title rule — the same one employee data requests
# inherit via EmployeeDataRequestRevision#valid_as_employee.
RSpec.describe User, "job title" do
  let(:business) { create(:business) }
  let(:user)     { create(:user, business: business) }

  before { create(:job_title, business: business, name: "مصفف شعر") }

  it "accepts a title from the business's active list" do
    expect(user.update(job_title: "مصفف شعر")).to be(true)
  end

  it "rejects a title that is not in the list" do
    expect(user.update(job_title: "وظيفة مخترعة")).to be(false)
    expect(user.errors.of_kind?(:job_title, :not_in_list)).to be(true)
  end

  it "rejects a title from another business or an inactive one" do
    create(:job_title, business: create(:business), name: "محاسب")
    create(:job_title, business: business, name: "قديم", active: false)
    expect(user.update(job_title: "محاسب")).to be(false)
    expect(user.update(job_title: "قديم")).to be(false)
  end

  it "leaves an unchanged legacy title alone" do
    user.update_column(:job_title, "لقب قديم")
    expect(user.reload.update(first_name: "Changed")).to be(true)
  end

  it "allows a blank title" do
    expect(user.update(job_title: "")).to be(true)
  end
end
