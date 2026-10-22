require "rails_helper"

# SAL — the Workforce UI-composition contract Employee::ProfilePanels. The page's
# behaviour stays pinned by spec/characterization/workforce/employee_salary_panel_spec.rb.
RSpec.describe Employee::ProfilePanels do
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  let(:viewer)   { instance_double(User) }
  let(:employee) { instance_double(User) }
  let(:panel)    { described_class::Panel.new(partial: "x/panel", locals: { a: 1 }) }

  it "lists its operation and has the Attendance & Payroll implementation registered at boot" do
    expect(described_class::OPERATIONS).to eq(%i[salary_panel])
    expect(described_class::Panel.members).to eq(%i[partial locals])
    expect(described_class.handler).to equal(Payroll::EmployeeSalaryPanel)
  end

  it "rejects an incomplete handler and raises NotRegistered without one" do
    with_handler(:current) do
      expect { described_class.register(Module.new) }.to raise_error(ArgumentError, /salary_panel/)
      expect(described_class.handler).to eq(:current)
    end
    with_handler(nil) do
      expect { described_class.salary_panel(viewer: viewer, employee: employee) }
        .to raise_error(described_class::NotRegistered)
    end
  end

  it "dispatches and passes a Panel or nil through" do
    handler = double("handler", salary_panel: panel)
    with_handler(handler) { expect(described_class.salary_panel(viewer: viewer, employee: employee)).to equal(panel) }
    expect(handler).to have_received(:salary_panel).with(viewer: viewer, employee: employee)
    with_handler(double("none", salary_panel: nil)) do
      expect(described_class.salary_panel(viewer: viewer, employee: employee)).to be_nil
    end
  end

  it "refuses a result of the wrong shape" do
    [ "x/panel", { partial: "x" }, described_class::Panel.new(partial: :x, locals: {}),
      described_class::Panel.new(partial: "x", locals: nil) ].each do |bad|
      with_handler(double("bad", salary_panel: bad)) do
        expect { described_class.salary_panel(viewer: viewer, employee: employee) }.to raise_error(ArgumentError)
      end
    end
  end

  it "names nothing from Attendance & Payroll" do
    code = File.read(Rails.root.join("app/services/employee/profile_panels.rb")).lines.grep_v(/^\s*#/).join
    expect(code).not_to match(/\bSalary(Profile)?\b|Salary::|Payroll|salary_profiles/)
  end
end
