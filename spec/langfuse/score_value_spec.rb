# frozen_string_literal: true

RSpec.describe Langfuse::ScoreValue do
  describe ".normalize" do
    it "preserves numeric values" do
      expect(described_class.normalize(0.75, :numeric)).to eq(0.75)
    end

    it "normalizes boolean values to the ingestion representation" do
      expect(described_class.normalize(true, :boolean)).to eq(1)
      expect(described_class.normalize(false, :boolean)).to eq(0)
    end

    it "preserves categorical strings" do
      expect(described_class.normalize("high", :categorical)).to eq("high")
    end

    it "accepts text values through the 500-character boundary" do
      value = "a" * 500

      expect(described_class.normalize(value, :text)).to equal(value)
    end

    it "rejects text outside the documented length range" do
      expect { described_class.normalize("", :text) }
        .to raise_error(ArgumentError, /1 to 500 characters, got 0/)
      expect { described_class.normalize("a" * 501, :text) }
        .to raise_error(ArgumentError, /1 to 500 characters, got 501/)
    end

    it "accepts correction strings without an invented length limit" do
      value = "a" * 10_000

      expect(described_class.normalize(value, :correction)).to equal(value)
    end

    it "rejects values that do not match the requested data type" do
      expect { described_class.normalize("no", :numeric) }.to raise_error(ArgumentError, /Numeric/)
      expect { described_class.normalize(2, :boolean) }.to raise_error(ArgumentError, /Boolean/)
      expect { described_class.normalize(1, :categorical) }.to raise_error(ArgumentError, /Categorical/)
      expect { described_class.normalize(1, :text) }.to raise_error(ArgumentError, /Text/)
      expect { described_class.normalize(1, :correction) }.to raise_error(ArgumentError, /Correction/)
    end

    it "rejects unknown data types" do
      expect { described_class.normalize("value", :unknown) }
        .to raise_error(ArgumentError, "Invalid data_type: unknown")
    end
  end
end
