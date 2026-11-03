require "rails_helper"

# BUG-042 (found by the Tenant Isolation Gate inventory, 2026-11-03): the
# employee form's department_id accepted another business's department — on
# create and update — whose name then showed on the employee's pages, and which
# that business's later hard delete would silently clear on our employee
# (Department has_many :users, dependent: :nullify). User now validates that
# its department belongs to the user's business.
RSpec.describe "Security: employee department business isolation", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:hr_user) do
    api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "business" })
  end
  let!(:department)         { create(:department, business: business, name: "Own Department") }
  let!(:foreign_department) { create(:department, business: other, name: "Foreign Department Secret") }
  let!(:employee) { create(:user, business: business, email: "emp@example.com", department: department) }

  before { sign_in hr_user }

  def create_params(department_id)
    { user: { first_name: "New", last_name: "Hire", email: "new-#{SecureRandom.hex(3)}@example.com",
              department_id: department_id } }
  end

  it "refuses creating an employee in another business's department (422, nothing saved)" do
    expect { post admin_users_path, params: create_params(foreign_department.id) }.not_to change(User, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(foreign_department.users).to be_empty
  end

  it "refuses moving an employee into another business's department" do
    patch admin_user_path(employee), params: { user: { department_id: foreign_department.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(employee.reload.department).to eq(department)
    expect(foreign_department.users).to be_empty
  end

  it "refuses it for the business owner too" do
    owner = create(:user, :owner, business: business)
    sign_in owner

    patch admin_user_path(employee), params: { user: { department_id: foreign_department.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(employee.reload.department).to eq(department)
  end

  it "still accepts the business's own department, and clearing it" do
    other_department = create(:department, business: business, name: "Second Department")

    post admin_users_path, params: create_params(department.id)
    expect(User.order(:id).last.department).to eq(department)

    patch admin_user_path(employee), params: { user: { department_id: other_department.id } }
    expect(response).to redirect_to(admin_users_path)
    expect(employee.reload.department).to eq(other_department)

    patch admin_user_path(employee), params: { user: { department_id: "" } }
    expect(response).to redirect_to(admin_users_path)
    expect(employee.reload.department).to be_nil
  end

  it "keeps saving an employee whose department is unchanged" do
    patch admin_user_path(employee), params: { user: { first_name: "Renamed" } }

    expect(response).to redirect_to(admin_users_path)
    expect(employee.reload).to have_attributes(first_name: "Renamed", department: department)
  end

  it "the model refuses a foreign department on every write path" do
    employee.department = foreign_department

    expect(employee).not_to be_valid
    expect(employee.errors.details[:department_id]).to include(error: :other_business)
    expect(build(:user, business: business, department: foreign_department)).not_to be_valid
  end
end
