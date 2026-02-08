# frozen_string_literal: true

RSpec.describe Langfuse::Evaluation do
  describe "#initialize" do
    it "creates an evaluation with required params" do
      eval = described_class.new(name: "accuracy", value: 0.95)
      expect(eval.name).to eq("accuracy")
      expect(eval.value).to eq(0.95)
      expect(eval.data_type).to eq(:numeric)
      expect(eval.comment).to be_nil
      expect(eval.config_id).to be_nil
      expect(eval.metadata).to be_nil
    end

    it "accepts optional comment" do
      eval = described_class.new(name: "accuracy", value: 0.95, comment: "good result")
      expect(eval.comment).to eq("good result")
    end

    it "accepts optional config_id" do
      eval = described_class.new(name: "accuracy", value: 0.95, config_id: "cfg-123")
      expect(eval.config_id).to eq("cfg-123")
    end

    it "accepts optional metadata" do
      eval = described_class.new(name: "accuracy", value: 0.95, metadata: { source: "auto" })
      expect(eval.metadata).to eq({ source: "auto" })
    end

    it "accepts boolean data_type" do
      eval = described_class.new(name: "passed", value: true, data_type: :boolean)
      expect(eval.data_type).to eq(:boolean)
    end

    it "accepts categorical data_type" do
      eval = described_class.new(name: "quality", value: "high", data_type: :categorical)
      expect(eval.data_type).to eq(:categorical)
    end

    it "raises ArgumentError when name is nil" do
      expect { described_class.new(name: nil, value: 1.0) }
        .to raise_error(ArgumentError, "name is required")
    end

    it "raises ArgumentError when name is empty" do
      expect { described_class.new(name: "", value: 1.0) }
        .to raise_error(ArgumentError, "name is required")
    end

    it "raises ArgumentError for invalid data_type" do
      expect { described_class.new(name: "test", value: 1.0, data_type: :invalid) }
        .to raise_error(ArgumentError, /Invalid data_type: invalid/)
    end

    context "with value type validation" do
      it "raises ArgumentError for non-numeric value with numeric data_type" do
        expect { described_class.new(name: "test", value: "hello", data_type: :numeric) }
          .to raise_error(ArgumentError, /Numeric value must be Numeric, got String/)
      end

      it "accepts integer for numeric data_type" do
        eval = described_class.new(name: "test", value: 5)
        expect(eval.value).to eq(5)
      end

      it "accepts float for numeric data_type" do
        eval = described_class.new(name: "test", value: 0.85)
        expect(eval.value).to eq(0.85)
      end

      it "raises ArgumentError for non-boolean value with boolean data_type" do
        expect { described_class.new(name: "test", value: "yes", data_type: :boolean) }
          .to raise_error(ArgumentError, %r{Boolean value must be true/false or 0/1})
      end

      it "accepts true for boolean data_type" do
        eval = described_class.new(name: "test", value: true, data_type: :boolean)
        expect(eval.value).to be true
      end

      it "accepts false for boolean data_type" do
        eval = described_class.new(name: "test", value: false, data_type: :boolean)
        expect(eval.value).to be false
      end

      it "accepts 0 for boolean data_type" do
        eval = described_class.new(name: "test", value: 0, data_type: :boolean)
        expect(eval.value).to eq(0)
      end

      it "accepts 1 for boolean data_type" do
        eval = described_class.new(name: "test", value: 1, data_type: :boolean)
        expect(eval.value).to eq(1)
      end

      it "raises ArgumentError for non-string value with categorical data_type" do
        expect { described_class.new(name: "test", value: 42, data_type: :categorical) }
          .to raise_error(ArgumentError, /Categorical value must be a String, got Integer/)
      end

      it "accepts string for categorical data_type" do
        eval = described_class.new(name: "test", value: "high", data_type: :categorical)
        expect(eval.value).to eq("high")
      end
    end
  end

  describe "#to_h" do
    it "returns hash with all non-nil fields" do
      eval = described_class.new(name: "accuracy", value: 0.95, comment: "good")
      expect(eval.to_h).to eq({ name: "accuracy", value: 0.95, comment: "good", data_type: :numeric })
    end

    it "excludes nil comment" do
      eval = described_class.new(name: "accuracy", value: 0.95)
      expect(eval.to_h).to eq({ name: "accuracy", value: 0.95, data_type: :numeric })
    end

    it "includes config_id and metadata when present" do
      eval = described_class.new(
        name: "accuracy", value: 0.95,
        config_id: "cfg-1", metadata: { k: "v" }
      )
      expect(eval.to_h).to eq(
        name: "accuracy", value: 0.95, data_type: :numeric,
        config_id: "cfg-1", metadata: { k: "v" }
      )
    end
  end
end
