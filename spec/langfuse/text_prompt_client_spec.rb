# frozen_string_literal: true

RSpec.describe Langfuse::TextPromptClient do
  let(:prompt_data) do
    {
      "id" => "prompt-123",
      "name" => "greeting",
      "version" => 1,
      "prompt" => "Hello {{name}}!",
      "type" => "text",
      "labels" => ["production"],
      "tags" => ["customer-facing"],
      "config" => { "temperature" => 0.7 },
      "commitMessage" => "Initial version",
      "resolutionGraph" => { "nodes" => [{ "name" => "shared-system" }] }
    }
  end

  describe "#initialize" do
    it "creates a text prompt client" do
      client = described_class.new(prompt_data)
      expect(client).to be_a(described_class)
    end

    it "sets the name" do
      client = described_class.new(prompt_data)
      expect(client.name).to eq("greeting")
    end

    it "sets the version" do
      client = described_class.new(prompt_data)
      expect(client.version).to eq(1)
    end

    it "sets the prompt" do
      client = described_class.new(prompt_data)
      expect(client.prompt).to eq("Hello {{name}}!")
    end

    it "defaults is_fallback to false" do
      client = described_class.new(prompt_data)
      expect(client.is_fallback).to be(false)
    end

    it "sets is_fallback when explicitly provided" do
      client = described_class.new(prompt_data, is_fallback: true)
      expect(client.is_fallback).to be(true)
    end

    it "sets the labels" do
      client = described_class.new(prompt_data)
      expect(client.labels).to eq(["production"])
    end

    it "sets the tags" do
      client = described_class.new(prompt_data)
      expect(client.tags).to eq(["customer-facing"])
    end

    it "sets the config" do
      client = described_class.new(prompt_data)
      expect(client.config).to eq({ "temperature" => 0.7 })
    end

    it "sets the type" do
      client = described_class.new(prompt_data)
      expect(client.type).to eq("text")
    end

    it "sets the commit message" do
      client = described_class.new(prompt_data)
      expect(client.commit_message).to eq("Initial version")
    end

    it "sets the resolution graph" do
      client = described_class.new(prompt_data)
      expect(client.resolution_graph).to eq({ "nodes" => [{ "name" => "shared-system" }] })
    end

    it "defaults labels to empty array when not provided" do
      data = prompt_data.dup.tap { |d| d.delete("labels") }
      client = described_class.new(data)
      expect(client.labels).to eq([])
    end

    it "defaults tags to empty array when not provided" do
      data = prompt_data.dup.tap { |d| d.delete("tags") }
      client = described_class.new(data)
      expect(client.tags).to eq([])
    end

    it "defaults config to empty hash when not provided" do
      data = prompt_data.dup.tap { |d| d.delete("config") }
      client = described_class.new(data)
      expect(client.config).to eq({})
    end

    it "defaults optional metadata when not provided" do
      data = prompt_data.dup.tap do |d|
        d.delete("commitMessage")
        d.delete("resolutionGraph")
      end
      client = described_class.new(data)

      expect(client.commit_message).to be_nil
      expect(client.resolution_graph).to be_nil
    end

    context "with invalid prompt data" do
      it "raises ArgumentError when prompt_data is not a Hash" do
        expect { described_class.new("not a hash") }.to raise_error(
          ArgumentError, "prompt_data must be a Hash"
        )
      end

      it "raises ArgumentError when prompt field is missing" do
        data = prompt_data.dup.tap { |d| d.delete("prompt") }
        expect { described_class.new(data) }.to raise_error(
          ArgumentError, "prompt_data must include 'prompt' field"
        )
      end

      it "raises ArgumentError when name field is missing" do
        data = prompt_data.dup.tap { |d| d.delete("name") }
        expect { described_class.new(data) }.to raise_error(
          ArgumentError, "prompt_data must include 'name' field"
        )
      end

      it "raises ArgumentError when version field is missing" do
        data = prompt_data.dup.tap { |d| d.delete("version") }
        expect { described_class.new(data) }.to raise_error(
          ArgumentError, "prompt_data must include 'version' field"
        )
      end
    end
  end

  describe "#compile" do
    let(:client) { described_class.new(prompt_data) }

    context "with variables" do
      it "substitutes variables in the template" do
        result = client.compile(name: "Alice")
        expect(result).to eq("Hello Alice!")
      end

      it "handles multiple variables" do
        data = prompt_data.merge("prompt" => "{{greeting}} {{name}}, welcome to {{place}}!")
        client = described_class.new(data)
        result = client.compile(greeting: "Hi", name: "Bob", place: "Langfuse")
        expect(result).to eq("Hi Bob, welcome to Langfuse!")
      end

      it "handles string keys" do
        result = client.compile("name" => "Charlie")
        expect(result).to eq("Hello Charlie!")
      end

      it "leaves unmatched placeholders in output" do
        result = client.compile
        expect(result).to eq("Hello {{name}}!")
      end
    end

    context "without variables" do
      it "returns the prompt as-is" do
        data = prompt_data.merge("prompt" => "Hello world!")
        client = described_class.new(data)
        result = client.compile
        expect(result).to eq("Hello world!")
      end

      it "returns the prompt with placeholders when no variables provided" do
        result = client.compile
        expect(result).to eq("Hello {{name}}!")
      end
    end

    context "with complex templates" do
      it "handles nested object properties" do
        data = prompt_data.merge("prompt" => "User: {{user.name}}, Email: {{user.email}}")
        client = described_class.new(data)
        result = client.compile(
          user: { name: "Alice", email: "alice@example.com" }
        )
        expect(result).to eq("User: Alice, Email: alice@example.com")
      end

      it "handles conditional sections" do
        data = prompt_data.merge("prompt" => "Hello{{#admin}} Admin{{/admin}}!")
        client = described_class.new(data)

        result_admin = client.compile(admin: true)
        expect(result_admin).to eq("Hello Admin!")

        result_user = client.compile(admin: false)
        expect(result_user).to eq("Hello!")
      end

      it "handles list iteration" do
        data = prompt_data.merge("prompt" => "Users: {{#users}}{{name}}, {{/users}}")
        client = described_class.new(data)
        result = client.compile(
          users: [
            { name: "Alice" },
            { name: "Bob" },
            { name: "Charlie" }
          ]
        )
        expect(result).to eq("Users: Alice, Bob, Charlie, ")
      end
    end

    context "with special characters" do
      it "preserves HTML-like content with normal variable tags" do
        data = prompt_data.merge("prompt" => "Message: {{message}}")
        client = described_class.new(data)
        result = client.compile(message: "<script>alert('hi')</script>")
        expect(result).to eq("Message: <script>alert('hi')</script>")
      end

      it "preserves quotes and newlines" do
        data = prompt_data.merge("prompt" => "Text: {{text}}")
        client = described_class.new(data)
        result = client.compile(text: "Line 1\nLine 2\n\"quoted\"")
        expect(result).to eq("Text: Line 1\nLine 2\n\"quoted\"")
      end

      it "preserves JSON-like values" do
        data = prompt_data.merge("prompt" => "Schema: {{schema}}")
        client = described_class.new(data)
        result = client.compile(schema: '{"title":"<name>","required":["id"]}')

        expect(result).to eq('Schema: {"title":"<name>","required":["id"]}')
      end

      it "keeps triple braces compatible" do
        data = prompt_data.merge("prompt" => "Message: {{{message}}}")
        client = described_class.new(data)
        result = client.compile(message: "<script>alert('hi')</script>")
        expect(result).to eq("Message: <script>alert('hi')</script>")
      end
    end

    context "with keyword arguments (new API style)" do
      it "accepts variables as direct keyword arguments" do
        result = client.compile(name: "Alice")
        expect(result).to eq("Hello Alice!")
      end

      it "works with no arguments" do
        result = client.compile
        expect(result).to eq("Hello {{name}}!")
      end

      it "handles multiple keyword arguments" do
        data = prompt_data.merge("prompt" => "{{greeting}} {{name}}, welcome to {{place}}!")
        client = described_class.new(data)
        result = client.compile(greeting: "Hi", name: "Bob", place: "Langfuse")
        expect(result).to eq("Hi Bob, welcome to Langfuse!")
      end
    end
  end
end
