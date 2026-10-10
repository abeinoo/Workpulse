require "rails_helper"

RSpec.describe PhoneNumber do
  describe ".equivalent?" do
    context "with an Egyptian mobile stored in national form" do
      let(:stored) { "01012345678" }

      [
        "01012345678", "+201012345678", "201012345678", "00201012345678",
        "+20 101 234 5678", "010-1234-5678", " 01012345678 ",
        "٠١٠١٢٣٤٥٦٧٨", "+٢٠١٠١٢٣٤٥٦٧٨", "۰۱۰۱۲۳۴۵۶۷۸"
      ].each do |input|
        it "matches #{input.inspect}" do
          expect(described_class.equivalent?(stored, input)).to be(true)
        end
      end

      [ "01012345679", "+201012345679", "1012345678", "+9661012345678", "+2001012345678", "" ].each do |input|
        it "does not match #{input.inspect}" do
          expect(described_class.equivalent?(stored, input)).to be(false)
        end
      end
    end

    it "matches an Egyptian mobile stored in international form against the national form" do
      expect(described_class.equivalent?("+201112345678", "01112345678")).to be(true)
      expect(described_class.equivalent?("+201512345678", "01512345678")).to be(true)
    end

    context "with a non-Egyptian number" do
      let(:stored) { "+966501234567" }

      it "keeps the existing international matching" do
        expect(described_class.equivalent?(stored, "+966 50 123 4567")).to be(true)
        expect(described_class.equivalent?(stored, "00966501234567")).to be(true)
        expect(described_class.equivalent?(stored, "+٩٦٦٥٠١٢٣٤٥٦٧")).to be(true)
      end

      it "never reinterprets a local number as Egyptian or Saudi" do
        expect(described_class.equivalent?(stored, "0501234567")).to be(false)
        expect(described_class.equivalent?("0501234567", "+20501234567")).to be(false)
      end
    end

    it "only treats the strict Egyptian mobile pattern (01[0125] + 8 digits) as Egyptian" do
      expect(described_class.equivalent?("01312345678", "+201312345678")).to be(false)
      expect(described_class.equivalent?("0101234567", "+20101234567")).to be(false)
    end

    it "never matches a blank stored number" do
      expect(described_class.equivalent?(nil, "")).to be(false)
      expect(described_class.equivalent?("", "+")).to be(false)
      expect(described_class.equivalent?(nil, "01012345678")).to be(false)
    end
  end

  describe ".stored_forms" do
    it "lists every stored form of an Egyptian mobile, whichever format was typed" do
      expected = %w[+201012345678 00201012345678 01012345678 201012345678]
      [ "01012345678", "+201012345678", "201012345678", "00201012345678", "٠١٠١٢٣٤٥٦٧٨" ].each do |typed|
        expect(described_class.stored_forms(typed)).to match_array(expected)
      end
    end

    it "keeps non-Egyptian numbers to their own international forms" do
      expect(described_class.stored_forms("+966 50 123 4567")).to match_array(%w[+966501234567 00966501234567])
      expect(described_class.stored_forms("0501234567")).to eq(%w[0501234567])
    end

    it "is empty for input without digits" do
      expect(described_class.stored_forms("")).to eq([])
      expect(described_class.stored_forms("+")).to eq([])
      expect(described_class.stored_forms("abc")).to eq([])
    end

    it "is exactly the set of stored values .equivalent? accepts" do
      stored_values = %w[01012345678 +201012345678 201012345678 00201012345678 01012345679
                         +966501234567 00966501234567 0501234567 +20501234567 01312345678]
      [ "01012345678", "+966501234567", "0501234567", "01312345678" ].each do |typed|
        expected = stored_values.select { |stored| described_class.equivalent?(stored, typed) }
        expect(stored_values & described_class.stored_forms(typed)).to match_array(expected)
      end
    end
  end
end
