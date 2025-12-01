# frozen_string_literal: true

require "spec_helper"

RSpec.describe Langfuse::Propagation do
  before do
    Langfuse.configure do |config|
      config.public_key = "pk_test"
      config.secret_key = "sk_test"
    end
  end

  describe ".propagate_attributes" do
    context "when called without a block" do
      it "raises ArgumentError" do
        expect do
          described_class.propagate_attributes(user_id: "user_123")
        end.to raise_error(ArgumentError, "Block required")
      end
    end

    context "with user_id" do
      it "sets user_id on current span" do
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(user_id: "user_123") do
            # Check that user_id is set on the current span
            attrs = span.otel_span.attributes
            expect(attrs["user.id"]).to eq("user_123")
          end
        end
      end

      it "propagates user_id to child spans" do
        described_class.propagate_attributes(user_id: "user_123") do
          parent = Langfuse.observe("parent")
          child = parent.start_observation("child")

          # Check that child span has user_id
          attrs = child.otel_span.attributes
          expect(attrs["user.id"]).to eq("user_123")

          child.end
          parent.end
        end
      end
    end

    context "with session_id" do
      it "sets session_id on current span" do
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(session_id: "session_abc") do
            attrs = span.otel_span.attributes
            expect(attrs["session.id"]).to eq("session_abc")
          end
        end
      end
    end

    context "with version" do
      it "sets version on current span" do
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(version: "v1.2.3") do
            attrs = span.otel_span.attributes
            expect(attrs["langfuse.version"]).to eq("v1.2.3")
          end
        end
      end
    end

    context "with tags" do
      it "sets tags on current span" do
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(tags: %w[production api-v2]) do
            attrs = span.otel_span.attributes
            tags_value = attrs["langfuse.trace.tags"]
            expect(tags_value).to be_a(String) # JSON serialized
            tags = JSON.parse(tags_value)
            expect(tags).to contain_exactly("production", "api-v2")
          end
        end
      end

      it "merges tags from nested contexts" do
        described_class.propagate_attributes(tags: %w[outer shared]) do
          described_class.propagate_attributes(tags: %w[inner shared]) do
            span = Langfuse.observe("test")
            attrs = span.otel_span.attributes
            tags_value = attrs["langfuse.trace.tags"]
            tags = JSON.parse(tags_value)
            # Should contain all tags, with duplicates removed
            expect(tags).to include("outer", "inner", "shared")
            expect(tags.count("shared")).to eq(1)
            span.end
          end
        end
      end
    end

    context "with metadata" do
      it "sets metadata on current span" do
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(metadata: { environment: "production", region: "us-east" }) do
            attrs = span.otel_span.attributes
            expect(attrs["langfuse.trace.metadata.environment"]).to eq("production")
            expect(attrs["langfuse.trace.metadata.region"]).to eq("us-east")
          end
        end
      end

      it "merges metadata from nested contexts" do
        described_class.propagate_attributes(metadata: { key1: "value1" }) do
          described_class.propagate_attributes(metadata: { key2: "value2" }) do
            span = Langfuse.observe("test")
            attrs = span.otel_span.attributes
            expect(attrs["langfuse.trace.metadata.key1"]).to eq("value1")
            expect(attrs["langfuse.trace.metadata.key2"]).to eq("value2")
            span.end
          end
        end
      end

      it "overwrites metadata keys with same name" do
        described_class.propagate_attributes(metadata: { key1: "value1" }) do
          described_class.propagate_attributes(metadata: { key1: "value2" }) do
            span = Langfuse.observe("test")
            attrs = span.otel_span.attributes
            expect(attrs["langfuse.trace.metadata.key1"]).to eq("value2")
            span.end
          end
        end
      end
    end

    context "with validation" do
      it "drops values over 200 characters" do
        long_value = "a" * 201
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(user_id: long_value) do
            attrs = span.otel_span.attributes
            expect(attrs["user.id"]).to be_nil
          end
        end
      end

      it "drops non-string values" do
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(user_id: 12_345) do
            attrs = span.otel_span.attributes
            expect(attrs["user.id"]).to be_nil
          end
        end
      end

      it "allows values exactly 200 characters" do
        value200 = "a" * 200
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(user_id: value200) do
            attrs = span.otel_span.attributes
            expect(attrs["user.id"]).to eq(value200)
          end
        end
      end
    end

    context "with no active span" do
      it "does not error" do
        expect do
          described_class.propagate_attributes(user_id: "user_123") do
            # No active span, but should not error
            result = "test"
            expect(result).to eq("test")
          end
        end.not_to raise_error
      end
    end

    context "with empty values" do
      it "handles nil values gracefully" do
        expect do
          described_class.propagate_attributes(user_id: nil, session_id: nil) do
            span = Langfuse.observe("test")
            span.end
          end
        end.not_to raise_error
      end

      it "handles empty tags array" do
        expect do
          described_class.propagate_attributes(tags: []) do
            span = Langfuse.observe("test")
            span.end
          end
        end.not_to raise_error
      end

      it "handles empty metadata hash" do
        expect do
          described_class.propagate_attributes(metadata: {}) do
            span = Langfuse.observe("test")
            span.end
          end
        end.not_to raise_error
      end
    end

    context "with multiple attributes" do
      it "sets all attributes on current span" do
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(
            user_id: "user_123",
            session_id: "session_abc",
            version: "v1.2.3",
            tags: ["production"],
            metadata: { environment: "prod" }
          ) do
            attrs = span.otel_span.attributes
            expect(attrs["user.id"]).to eq("user_123")
            expect(attrs["session.id"]).to eq("session_abc")
            expect(attrs["langfuse.version"]).to eq("v1.2.3")
            tags = JSON.parse(attrs["langfuse.trace.tags"])
            expect(tags).to include("production")
            expect(attrs["langfuse.trace.metadata.environment"]).to eq("prod")
          end
        end
      end
    end

    context "with return value" do
      it "returns the result of the block" do
        result = described_class.propagate_attributes(user_id: "user_123") do
          "block_result"
        end

        expect(result).to eq("block_result")
      end
    end

    context "with baggage propagation" do
      context "when baggage is not available" do
        before do
          # Stub baggage_available? to return false
          allow(described_class).to receive(:baggage_available?).and_return(false)
        end

        it "warns when as_baggage is requested but baggage is not available" do
          expect(Langfuse.configuration.logger).to receive(:warn).with(
            /Baggage propagation requested but opentelemetry-baggage gem not available/
          )

          described_class.propagate_attributes(user_id: "user_123", as_baggage: true) do
            # Should still work, just without baggage
          end
        end
      end

      context "when baggage is available" do
        before do
          # Mock OpenTelemetry::Baggage to be available
          baggage_module = Module.new do
            def self.set_value(context:, key:, value:)
              new_baggage = (context.value("baggage") || {}).dup
              new_baggage[key] = value
              context.set_value("baggage", new_baggage)
            end

            def self.value(context:)
              context.value("baggage") || {}
            end
          end

          stub_const("OpenTelemetry::Baggage", baggage_module)
          allow(described_class).to receive(:baggage_available?).and_return(true)
        end

        it "sets baggage attributes when as_baggage is true" do
          described_class.propagate_attributes(user_id: "user_123", as_baggage: true) do
            context = OpenTelemetry::Context.current
            baggage = OpenTelemetry::Baggage.value(context: context)
            expect(baggage["langfuse_user_id"]).to eq("user_123")
          end
        end

        it "sets baggage for session_id" do
          described_class.propagate_attributes(session_id: "session_abc", as_baggage: true) do
            context = OpenTelemetry::Context.current
            baggage = OpenTelemetry::Baggage.value(context: context)
            expect(baggage["langfuse_session_id"]).to eq("session_abc")
          end
        end

        it "sets baggage for version" do
          described_class.propagate_attributes(version: "v1.2.3", as_baggage: true) do
            context = OpenTelemetry::Context.current
            baggage = OpenTelemetry::Baggage.value(context: context)
            expect(baggage["langfuse_version"]).to eq("v1.2.3")
          end
        end

        it "sets baggage for tags as comma-separated string" do
          described_class.propagate_attributes(tags: %w[tag1 tag2], as_baggage: true) do
            context = OpenTelemetry::Context.current
            baggage = OpenTelemetry::Baggage.value(context: context)
            expect(baggage["langfuse_tags"]).to eq("tag1,tag2")
          end
        end

        it "sets baggage for metadata with prefixed keys" do
          described_class.propagate_attributes(metadata: { env: "prod", region: "us-east" }, as_baggage: true) do
            context = OpenTelemetry::Context.current
            baggage = OpenTelemetry::Baggage.value(context: context)
            expect(baggage["langfuse_metadata_env"]).to eq("prod")
            expect(baggage["langfuse_metadata_region"]).to eq("us-east")
          end
        end

        it "handles baggage setting errors gracefully" do
          # Mock baggage to raise an error
          allow(OpenTelemetry::Baggage).to receive(:set_value).and_raise(StandardError.new("Baggage error"))

          expect(Langfuse.configuration.logger).to receive(:warn).with(/Failed to set baggage/)

          described_class.propagate_attributes(user_id: "user_123", as_baggage: true) do
            # Should not raise, just log warning
          end
        end
      end
    end

    context "with array validation" do
      it "filters out invalid values from arrays" do
        # Array with mix of valid and invalid (non-string) values
        Langfuse.observe("test-operation") do |span|
          described_class.propagate_attributes(tags: ["valid", 123, "also_valid"]) do
            attrs = span.otel_span.attributes
            tags_value = attrs["langfuse.trace.tags"]
            if tags_value
              tags = JSON.parse(tags_value)
              expect(tags).to contain_exactly("valid", "also_valid")
            end
          end
        end
      end
    end

    context "with non-string validation warnings" do
      it "warns when non-string value is provided" do
        expect(Langfuse.configuration.logger).to receive(:warn).with(
          /Propagated attribute 'user_id' value is not a string/
        )

        Langfuse.observe("test-operation") do |_span|
          described_class.propagate_attributes(user_id: 12_345) do
            # Should warn but not error
          end
        end
      end
    end
  end

  describe ".get_propagated_attributes_from_context" do
    it "extracts attributes from context" do
      # Set values in context (simulating what propagate_attributes does)
      # Note: This test might need adjustment based on actual OpenTelemetry Ruby API
      described_class.propagate_attributes(
        user_id: "user_123",
        session_id: "session_abc",
        metadata: { env: "test" }
      ) do
        new_context = OpenTelemetry::Context.current
        attrs = described_class.get_propagated_attributes_from_context(new_context)

        expect(attrs["user.id"]).to eq("user_123")
        expect(attrs["session.id"]).to eq("session_abc")
        expect(attrs["langfuse.trace.metadata.env"]).to eq("test")
      end
    end

    context "with baggage extraction" do
      before do
        # Mock OpenTelemetry::Baggage to be available
        baggage_module = Module.new do
          def self.set_value(context:, key:, value:)
            new_baggage = (context.value("baggage") || {}).dup
            new_baggage[key] = value
            context.set_value("baggage", new_baggage)
          end

          def self.value(context:)
            context.value("baggage") || {}
          end
        end

        stub_const("OpenTelemetry::Baggage", baggage_module)
        allow(described_class).to receive(:baggage_available?).and_return(true)
      end

      it "extracts attributes from baggage" do
        # Set baggage directly
        context = OpenTelemetry::Context.current
        context = OpenTelemetry::Baggage.set_value(context: context, key: "langfuse_user_id", value: "baggage_user")
        context = OpenTelemetry::Baggage.set_value(context: context, key: "langfuse_session_id",
                                                   value: "baggage_session")

        attrs = described_class.get_propagated_attributes_from_context(context)

        expect(attrs["user.id"]).to eq("baggage_user")
        expect(attrs["session.id"]).to eq("baggage_session")
      end

      it "extracts tags from baggage as comma-separated string" do
        context = OpenTelemetry::Context.current
        context = OpenTelemetry::Baggage.set_value(context: context, key: "langfuse_tags", value: "tag1,tag2,tag3")

        attrs = described_class.get_propagated_attributes_from_context(context)

        expect(attrs["langfuse.trace.tags"]).to eq(%w[tag1 tag2 tag3])
      end

      it "extracts metadata keys from baggage" do
        context = OpenTelemetry::Context.current
        context = OpenTelemetry::Baggage.set_value(context: context, key: "langfuse_metadata_env", value: "production")
        context = OpenTelemetry::Baggage.set_value(context: context, key: "langfuse_metadata_region", value: "us-east")

        attrs = described_class.get_propagated_attributes_from_context(context)

        expect(attrs["langfuse.trace.metadata.env"]).to eq("production")
        expect(attrs["langfuse.trace.metadata.region"]).to eq("us-east")
      end

      it "ignores non-Langfuse baggage keys" do
        context = OpenTelemetry::Context.current
        context = OpenTelemetry::Baggage.set_value(context: context, key: "other_key", value: "other_value")
        context = OpenTelemetry::Baggage.set_value(context: context, key: "langfuse_user_id", value: "user_123")

        attrs = described_class.get_propagated_attributes_from_context(context)

        expect(attrs["user.id"]).to eq("user_123")
        expect(attrs["other_key"]).to be_nil
      end

      it "handles baggage extraction errors gracefully" do
        # Mock baggage to raise an error
        allow(OpenTelemetry::Baggage).to receive(:value).and_raise(StandardError.new("Baggage error"))
        allow(described_class).to receive(:baggage_available?).and_return(true)

        expect(Langfuse.configuration.logger).to receive(:debug).with(/Baggage extraction failed/)

        context = OpenTelemetry::Context.current
        attrs = described_class.get_propagated_attributes_from_context(context)

        expect(attrs).to eq({})
      end
    end
  end

  describe "._get_span_key_from_baggage_key" do
    it "returns nil for non-Langfuse baggage keys" do
      expect(described_class.send(:_get_span_key_from_baggage_key, "other_key")).to be_nil
    end

    it "maps user_id baggage key" do
      expect(described_class.send(:_get_span_key_from_baggage_key, "langfuse_user_id")).to eq("user.id")
    end

    it "maps session_id baggage key" do
      expect(described_class.send(:_get_span_key_from_baggage_key, "langfuse_session_id")).to eq("session.id")
    end

    it "maps version baggage key" do
      expect(described_class.send(:_get_span_key_from_baggage_key, "langfuse_version")).to eq("langfuse.version")
    end

    it "maps tags baggage key" do
      expect(described_class.send(:_get_span_key_from_baggage_key, "langfuse_tags")).to eq("langfuse.trace.tags")
    end

    it "maps metadata baggage keys" do
      expect(described_class.send(:_get_span_key_from_baggage_key,
                                  "langfuse_metadata_env")).to eq("langfuse.trace.metadata.env")
      expect(described_class.send(:_get_span_key_from_baggage_key,
                                  "langfuse_metadata_region")).to eq("langfuse.trace.metadata.region")
    end
  end
end
