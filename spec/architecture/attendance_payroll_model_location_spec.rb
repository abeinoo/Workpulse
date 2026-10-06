require "rails_helper"

# Milestone 2 Pilot 1 (M7): the biometric models live physically in Attendance &
# Payroll (app/models/attendance_payroll/, a collapsed directory) but keep their
# top-level constants and tables (Q-M2-1). Guards against an accidental
# un-collapse, namespace or table change.
RSpec.describe "Architecture: Attendance & Payroll model location" do
  { BiometricDevice => "biometric_devices", BiometricPunchLog => "biometric_punch_logs" }.each do |model, table|
    describe model.name do
      it "loads as a top-level constant from app/models/attendance_payroll/" do
        expect(model.name).to eq(model.name.demodulize) # resolving the constant also triggers the autoload
        path = Object.const_source_location(model.name).first
        expect(path).to eq(Rails.root.join("app/models/attendance_payroll/#{model.name.underscore}.rb").to_s)
      end

      it "no longer has a top-level model file" do
        expect(File).not_to exist(Rails.root.join("app/models/#{model.name.underscore}.rb"))
      end

      it "keeps #{table} as its table" do
        expect(model.table_name).to eq(table)
      end

      it "is not namespaced under AttendancePayroll" do
        expect(defined?(::AttendancePayroll)).to be_nil.or(satisfy { !::AttendancePayroll.const_defined?(model.name, false) })
      end
    end
  end

  it "is the same class every association resolves" do
    expect(Business.reflect_on_association(:biometric_devices).klass).to equal(BiometricDevice)
    expect(Business.reflect_on_association(:biometric_punch_logs).klass).to equal(BiometricPunchLog)
    expect(AttendanceRecord.reflect_on_association(:biometric_punch_logs).klass).to equal(BiometricPunchLog)
    expect(BiometricDevice.reflect_on_association(:biometric_punch_logs).klass).to equal(BiometricPunchLog)
    expect(BiometricPunchLog.reflect_on_association(:biometric_device).klass).to equal(BiometricDevice)
    expect(BiometricPunchLog.reflect_on_association(:employee).klass).to equal(User)
    expect(BiometricPunchLog.reflect_on_association(:attendance_record).klass).to equal(AttendanceRecord)
  end

  it "is the class the device policy and services operate on" do
    expect(Pundit::PolicyFinder.new(BiometricDevice).policy).to equal(BiometricDevicePolicy)
    expect(Pundit::PolicyFinder.new(BiometricDevice.new).policy).to equal(BiometricDevicePolicy)
  end
end
