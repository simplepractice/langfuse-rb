# frozen_string_literal: true

RSpec.describe Langfuse::ChatPromptClient do
  let(:prompt_data) do
    {
      "id" => "prompt-456",
      "name" => "support_chat",
      "version" => 2,
      "prompt" => [
        {
          "role" => "system",
          "content" => "You are a helpful assistant for {{company_name}}."
        },
        {
          "role" => "user",
          "content" => "Hello, I need help with {{issue}}."
        }
      ],
      "type" => "chat",
      "labels" => %w[production support],
      "tags" => %w[customer-facing critical],
      "config" => { "temperature" => 0.7, "max_tokens" => 500 }
    }
  end

  describe "#initialize" do
    it "creates a chat prompt client" do
      client = described_class.new(prompt_data)
      expect(client).to be_a(described_class)
    end

    it "sets the name" do
      client = described_class.new(prompt_data)
      expect(client.name).to eq("support_chat")
    end

    it "sets the version" do
      client = described_class.new(prompt_data)
      expect(client.version).to eq(2)
    end

    it "sets the prompt" do
      client = described_class.new(prompt_data)
      expect(client.prompt).to eq(prompt_data["prompt"])
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
      expect(client.labels).to eq(%w[production support])
    end

    it "sets the tags" do
      client = described_class.new(prompt_data)
      expect(client.tags).to eq(%w[customer-facing critical])
    end

    it "sets the config" do
      client = described_class.new(prompt_data)
      expect(client.config).to eq({ "temperature" => 0.7, "max_tokens" => 500 })
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

      it "raises ArgumentError when prompt is not an Array" do
        data = prompt_data.merge("prompt" => "not an array")
        expect { described_class.new(data) }.to raise_error(
          ArgumentError, "prompt must be an Array"
        )
      end
    end
  end

  describe "#compile" do
    let(:client) { described_class.new(prompt_data) }

    context "with variables" do
      it "substitutes variables in all messages" do
        result = client.compile(company_name: "Acme Corp", issue: "login problems")

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant for Acme Corp." },
                               { role: :user, content: "Hello, I need help with login problems." }
                             ])
      end

      it "returns messages with symbol keys for role" do
        result = client.compile(company_name: "Test", issue: "test")

        expect(result[0][:role]).to eq(:system)
        expect(result[1][:role]).to eq(:user)
      end

      it "handles string variable keys" do
        result = client.compile("company_name" => "Test Co", "issue" => "billing")

        expect(result[0][:content]).to include("Test Co")
        expect(result[1][:content]).to include("billing")
      end
    end

    context "without variables" do
      it "returns messages with unsubstituted placeholders" do
        result = client.compile

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant for {{company_name}}." },
                               { role: :user, content: "Hello, I need help with {{issue}}." }
                             ])
      end

      it "handles messages without placeholders" do
        data = prompt_data.dup
        data["prompt"] = [{ "role" => "system", "content" => "You are helpful." }]
        client = described_class.new(data)

        result = client.compile

        expect(result).to eq([
                               { role: :system, content: "You are helpful." }
                             ])
      end
    end

    context "with different roles" do
      it "handles system, user, and assistant roles" do
        data = prompt_data.dup
        data["prompt"] = [
          { "role" => "system", "content" => "System message" },
          { "role" => "user", "content" => "User message" },
          { "role" => "assistant", "content" => "Assistant message" }
        ]
        client = described_class.new(data)

        result = client.compile

        expect(result.map { |m| m[:role] }).to eq(%i[system user assistant])
      end

      it "normalizes role case to lowercase symbols" do
        data = prompt_data.dup
        data["prompt"] = [
          { "role" => "SYSTEM", "content" => "test" },
          { "role" => "User", "content" => "test" }
        ]
        client = described_class.new(data)

        result = client.compile

        expect(result[0][:role]).to eq(:system)
        expect(result[1][:role]).to eq(:user)
      end
    end

    context "with message placeholders" do
      let(:placeholder_prompt_data) do
        prompt_data.merge(
          "prompt" => [
            { "role" => "system", "content" => "You are a {{role}} assistant." },
            { "type" => "placeholder", "name" => "history" },
            { "role" => "user", "content" => "Help me with {{task}}." }
          ]
        )
      end

      let(:client) { described_class.new(placeholder_prompt_data) }

      it "inserts placeholder messages and compiles their content" do
        result = client.compile(
          role: "helpful",
          task: "billing",
          history: [
            { role: :user, content: "Show {{task}} context" },
            { role: :assistant, content: "Prior answer", tool_calls: [{ id: "call_1" }] }
          ]
        )

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant." },
                               { role: :user, content: "Show billing context" },
                               { role: :assistant, content: "Prior answer", tool_calls: [{ id: "call_1" }] },
                               { role: :user, content: "Help me with billing." }
                             ])
      end

      it "skips placeholders resolved to empty arrays" do
        result = client.compile(role: "helpful", task: "billing", history: [])

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant." },
                               { role: :user, content: "Help me with billing." }
                             ])
      end

      it "keeps unresolved placeholders and warns" do
        expect(Langfuse.configuration.logger).to receive(:warn)
          .with(/Placeholders \["history"\] have not been resolved/)

        result = client.compile(role: "helpful", task: "billing")

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant." },
                               { type: "placeholder", name: "history" },
                               { role: :user, content: "Help me with billing." }
                             ])
      end

      it "degrades non-array placeholder values to a synthetic message and warns" do
        expect(Langfuse.configuration.logger).to receive(:warn)
          .with(/Placeholder 'history' must contain an array of chat messages/)

        result = client.compile(role: "helpful", task: "billing", history: "not a list")

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant." },
                               { role: :not_given, content: "not a list" },
                               { role: :user, content: "Help me with billing." }
                             ])
      end

      it "preserves valid messages and degrades malformed array entries" do
        placeholder_value = [
          "invalid message",
          { "role" => "user", "content" => "valid {{task}} message" }
        ]

        expect(Langfuse.configuration.logger).to receive(:warn)
          .with(/Placeholder 'history' should contain chat message hashes/)

        result = client.compile(role: "helpful", task: "billing", history: placeholder_value)

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant." },
                               { role: :not_given, content: placeholder_value.to_s },
                               { role: :user, content: "valid billing message" },
                               { role: :user, content: "Help me with billing." }
                             ])
      end
    end

    context "with complex templates" do
      it "handles nested object properties" do
        data = prompt_data.dup
        data["prompt"] = [
          {
            "role" => "system",
            "content" => "User: {{user.name}}, Email: {{user.email}}"
          }
        ]
        client = described_class.new(data)

        result = client.compile(
          user: { name: "Alice", email: "alice@example.com" }
        )

        expect(result[0][:content]).to eq("User: Alice, Email: alice@example.com")
      end

      it "handles conditionals in messages" do
        data = prompt_data.dup
        data["prompt"] = [
          {
            "role" => "system",
            "content" => "Hello{{#premium}} Premium User{{/premium}}!"
          }
        ]
        client = described_class.new(data)

        result_premium = client.compile(premium: true)
        expect(result_premium[0][:content]).to eq("Hello Premium User!")

        result_basic = client.compile(premium: false)
        expect(result_basic[0][:content]).to eq("Hello!")
      end

      it "handles list iteration" do
        data = prompt_data.dup
        data["prompt"] = [
          {
            "role" => "system",
            "content" => "Available options: {{#options}}{{name}}, {{/options}}"
          }
        ]
        client = described_class.new(data)

        result = client.compile(
          options: [
            { name: "Option A" },
            { name: "Option B" },
            { name: "Option C" }
          ]
        )

        expect(result[0][:content]).to eq("Available options: Option A, Option B, Option C, ")
      end
    end

    context "with multiple messages" do
      it "compiles each message independently" do
        data = prompt_data.dup
        data["prompt"] = [
          { "role" => "system", "content" => "Welcome to {{app_name}}" },
          { "role" => "user", "content" => "My name is {{user_name}}" },
          { "role" => "assistant", "content" => "Hello {{user_name}}!" }
        ]
        client = described_class.new(data)

        result = client.compile(app_name: "MyApp", user_name: "Bob")

        expect(result).to eq([
                               { role: :system, content: "Welcome to MyApp" },
                               { role: :user, content: "My name is Bob" },
                               { role: :assistant, content: "Hello Bob!" }
                             ])
      end

      it "handles different variables in different messages" do
        data = prompt_data.dup
        data["prompt"] = [
          { "role" => "system", "content" => "System {{var1}}" },
          { "role" => "user", "content" => "User {{var2}}" }
        ]
        client = described_class.new(data)

        result = client.compile(var1: "A", var2: "B")

        expect(result[0][:content]).to eq("System A")
        expect(result[1][:content]).to eq("User B")
      end
    end

    context "with special characters" do
      it "preserves HTML-like content with normal variable tags" do
        data = prompt_data.dup
        data["prompt"] = [
          { "role" => "user", "content" => "Message: {{message}}" }
        ]
        client = described_class.new(data)

        result = client.compile(message: "<script>alert('xss')</script>")

        expect(result[0][:content]).to eq("Message: <script>alert('xss')</script>")
      end

      it "preserves JSON-like values in message content" do
        data = prompt_data.dup
        data["prompt"] = [
          { "role" => "user", "content" => "Schema: {{schema}}" }
        ]
        client = described_class.new(data)

        result = client.compile(schema: '{"title":"<name>","required":["id"]}')

        expect(result[0][:content]).to eq('Schema: {"title":"<name>","required":["id"]}')
      end

      it "keeps triple braces compatible" do
        data = prompt_data.dup
        data["prompt"] = [
          { "role" => "user", "content" => "HTML: {{{html}}}" }
        ]
        client = described_class.new(data)

        result = client.compile(html: "<b>bold</b>")

        expect(result[0][:content]).to eq("HTML: <b>bold</b>")
      end
    end

    context "with empty messages" do
      it "handles messages with empty content" do
        data = prompt_data.dup
        data["prompt"] = [{ "role" => "system", "content" => "" }]
        client = described_class.new(data)

        result = client.compile

        expect(result).to eq([{ role: :system, content: "" }])
      end

      it "handles messages without content field" do
        data = prompt_data.dup
        data["prompt"] = [{ "role" => "system" }]
        client = described_class.new(data)

        result = client.compile

        expect(result).to eq([{ role: :system, content: "" }])
      end
    end

    context "with keyword arguments (new API style)" do
      it "accepts variables as direct keyword arguments" do
        result = client.compile(company_name: "Acme Corp", issue: "login problems")

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant for Acme Corp." },
                               { role: :user, content: "Hello, I need help with login problems." }
                             ])
      end

      it "works with no arguments" do
        result = client.compile

        expect(result).to eq([
                               { role: :system, content: "You are a helpful assistant for {{company_name}}." },
                               { role: :user, content: "Hello, I need help with {{issue}}." }
                             ])
      end

      it "handles single variable" do
        data = prompt_data.dup
        data["prompt"] = [{ "role" => "user", "content" => "{{text}}" }]
        client = described_class.new(data)

        result = client.compile(text: "Buy cheap meds now!!")

        expect(result).to eq([
                               { role: :user, content: "Buy cheap meds now!!" }
                             ])
      end
    end
  end
end
