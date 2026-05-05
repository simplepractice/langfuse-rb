# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::PromptClientFactory do
  let(:text_prompt_data) do
    {
      "name" => "greeting",
      "version" => 2,
      "type" => "text",
      "prompt" => "Hello {{name}}",
      "labels" => ["production"],
      "tags" => ["welcome"],
      "config" => { "temperature" => 0.1 },
      "commitMessage" => "ship it",
      "resolutionGraph" => { "nodes" => [] }
    }
  end

  let(:chat_prompt_data) do
    {
      "name" => "support",
      "version" => 3,
      "type" => "chat",
      "prompt" => [
        { "role" => "system", "content" => "Help {{name}}" },
        { "type" => "placeholder", "name" => "history" }
      ]
    }
  end

  describe ".build" do
    it "builds a text prompt client with shared metadata" do
      prompt = described_class.build(text_prompt_data)

      expect(prompt).to be_a(Langfuse::TextPromptClient)
      expect(prompt.name).to eq("greeting")
      expect(prompt.version).to eq(2)
      expect(prompt.labels).to eq(["production"])
      expect(prompt.tags).to eq(["welcome"])
      expect(prompt.config).to eq({ "temperature" => 0.1 })
      expect(prompt.commit_message).to eq("ship it")
      expect(prompt.resolution_graph).to eq({ "nodes" => [] })
      expect(prompt.is_fallback).to be false
    end

    it "builds a chat prompt client" do
      prompt = described_class.build(chat_prompt_data)

      expect(prompt).to be_a(Langfuse::ChatPromptClient)
      expect(prompt.compile(name: "Ada", history: [{ role: :user, content: "Hi" }])).to eq(
        [
          { role: :system, content: "Help Ada" },
          { role: :user, content: "Hi" }
        ]
      )
    end

    it "raises for unknown prompt types" do
      expect do
        described_class.build(text_prompt_data.merge("type" => "image"))
      end.to raise_error(Langfuse::ApiError, "Unknown prompt type: image")
    end
  end

  describe ".build_fallback" do
    it "builds fallback prompt clients without changing fallback metadata" do
      prompt = described_class.build_fallback("offline", "Fallback {{name}}", :text)

      expect(prompt).to be_a(Langfuse::TextPromptClient)
      expect(prompt.name).to eq("offline")
      expect(prompt.version).to eq(0)
      expect(prompt.tags).to eq(["fallback"])
      expect(prompt.is_fallback).to be true
      expect(prompt.compile(name: "Ada")).to eq("Fallback Ada")
    end
  end

  describe ".validate_type!" do
    it "preserves the public invalid type error" do
      expect do
        described_class.validate_type!(:json)
      end.to raise_error(ArgumentError, "Invalid type: json. Must be :text or :chat")
    end
  end

  describe ".validate_content!" do
    it "validates declared content shape" do
      expect { described_class.validate_content!("hello", :text) }.not_to raise_error
      expect { described_class.validate_content!([{ role: :user, content: "hi" }], :chat) }.not_to raise_error
      expect { described_class.validate_content!([], :text) }
        .to raise_error(ArgumentError, "Text prompt must be a String")
      expect { described_class.validate_content!("hello", :chat) }
        .to raise_error(ArgumentError, "Chat prompt must be an Array")
    end
  end

  describe ".normalize_content" do
    it "preserves placeholder entries and extra chat message fields" do
      prompt = [
        { role: :user, content: "Hi", cache_control: { type: "ephemeral" } },
        { type: "placeholder", name: :history }
      ]

      expect(described_class.normalize_content(prompt, :chat)).to eq(
        [
          { "role" => "user", "content" => "Hi", "cache_control" => { type: "ephemeral" } },
          { "type" => "placeholder", "name" => "history" }
        ]
      )
    end
  end
end
