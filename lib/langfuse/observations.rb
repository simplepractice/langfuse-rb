# frozen_string_literal: true

module Langfuse
  # Observation type constants
  OBSERVATION_TYPES = {
    span: "span",
    generation: "generation",
    embedding: "embedding",
    event: "event",
    agent: "agent",
    tool: "tool",
    chain: "chain",
    retriever: "retriever",
    evaluator: "evaluator",
    guardrail: "guardrail"
  }.freeze

  # Base class for all Langfuse observation wrappers.
  #
  # Provides unified functionality for spans, generations, events, and specialized observation types.
  # Wraps OpenTelemetry spans with Langfuse-specific functionality. Uses unified `start_observation()`
  # method with `as_type` parameter, aligning with langfuse-js architecture.
  #
  # @example Block-based API (auto-ends)
  #   Langfuse.observe("parent-operation", input: { query: "test" }) do |span|
  #     # Child span
  #     span.start_observation("data-processing", input: { step: "fetch" }) do |child|
  #       result = fetch_data
  #       child.update(output: result)
  #     end
  #
  #     # Child generation (LLM call)
  #     span.start_observation("llm-call", { model: "gpt-4", input: [{ role: "user", content: "Hello" }] }, as_type: :generation) do |gen|
  #       response = call_llm
  #       gen.update(output: response, usage_details: { prompt_tokens: 100, completion_tokens: 50 })
  #     end
  #   end
  #
  # @example Stateful API (manual end)
  #   span = Langfuse.start_observation("parent-operation", { input: { query: "test" } })
  #
  #   # Child span
  #   child_span = span.start_observation("data-validation", { input: { data: result } })
  #   validate_data
  #   child_span.update(output: { valid: true })
  #   child_span.end
  #
  #   # Child generation (LLM call)
  #   gen = span.start_observation("llm-summary", {
  #     model: "gpt-3.5-turbo",
  #     input: [{ role: "user", content: "Summarize" }]
  #   }, as_type: :generation)
  #   summary = call_llm
  #   gen.update(output: summary, usage_details: { prompt_tokens: 50, completion_tokens: 25 })
  #   gen.end
  #
  #   span.end
  #
  # @abstract Subclass and pass type: to super to create concrete observation types
  class BaseObservation
    attr_reader :otel_span, :otel_tracer, :type

    # @param otel_span [OpenTelemetry::SDK::Trace::Span] The underlying OTel span
    # @param otel_tracer [OpenTelemetry::SDK::Trace::Tracer] The OTel tracer
    # @param attributes [Hash, Types::SpanAttributes, Types::GenerationAttributes, nil] Optional initial attributes
    # @param type [String] Observation type (e.g., "span", "generation", "event")
    def initialize(otel_span, otel_tracer, attributes: nil, type: nil)
      @otel_span = otel_span
      @otel_tracer = otel_tracer
      @type = type || raise(ArgumentError, "type must be provided")

      # Set initial attributes if provided
      return unless attributes

      update_observation_attributes(attributes.to_h)
    end

    # @return [String] Hex-encoded span ID (16 hex characters)
    def id
      @otel_span.context.span_id.unpack1("H*")
    end

    # @return [String] Hex-encoded trace ID (32 hex characters)
    def trace_id
      @otel_span.context.trace_id.unpack1("H*")
    end

    # @return [String] URL to view this trace in Langfuse UI
    #
    # @example
    #   span = Langfuse.observe("operation") do |obs|
    #     puts "View trace: #{obs.trace_url}"
    #   end
    def trace_url
      Langfuse.client.trace_url(trace_id)
    end

    # @param end_time [Time, Integer, nil] Optional end time (Time object or Unix timestamp in nanoseconds)
    def end(end_time: nil)
      @otel_span.finish(end_timestamp: end_time)
    end

    # Updates trace-level attributes (user_id, session_id, tags, etc.) for the entire trace.
    #
    # @param attrs [Hash, Types::TraceAttributes] Trace attributes to set
    # @return [self]
    def update_trace(attrs)
      return self unless @otel_span.recording?

      otel_attrs = OtelAttributes.create_trace_attributes(attrs.to_h)
      otel_attrs.each { |key, value| @otel_span.set_attribute(key, value) }
      self
    end

    # Creates a child observation within this observation's context.
    #
    # Supports block-based (auto-ends) and stateful (manual end) APIs. Events auto-end when created without a block.
    #
    # @param name [String] Descriptive name for the child observation
    # @param attrs [Hash, Types::SpanAttributes, Types::GenerationAttributes, nil] Observation attributes
    # @param as_type [Symbol, String] Observation type (:span, :generation, :event, etc.). Defaults to `:span`.
    # @yield [observation] Optional block that receives the observation object
    # @return [BaseObservation, Object] The child observation (or block return value if block given)
    def start_observation(name, attrs = {}, as_type: :span, &block)
      # Call module-level factory with parent context
      # Skip validation to allow unknown types to fall back to Span
      child = Langfuse.start_observation(
        name,
        attrs,
        as_type: as_type,
        parent_span_context: @otel_span.context,
        skip_validation: true
      )

      if block
        # Block-based API: auto-ends when block completes
        # Set context and execute block
        current_context = OpenTelemetry::Context.current
        result = OpenTelemetry::Context.with_current(
          OpenTelemetry::Trace.context_with_span(child.otel_span, parent_context: current_context)
        ) do
          block.call(child)
        end
        # Only end if not already ended (events auto-end in start_observation)
        child.end unless as_type.to_s == OBSERVATION_TYPES[:event]
        result
      else
        # Stateful API - return observation
        # Events already auto-ended in start_observation
        child
      end
    end

    # Sets observation-level input attributes.
    #
    # @param value [Object] Input value (will be JSON-encoded)
    def input=(value)
      update_observation_attributes(input: value)
    end

    # Sets observation-level output attributes.
    #
    # @param value [Object] Output value (will be JSON-encoded)
    def output=(value)
      update_observation_attributes(output: value)
    end

    # @param value [Hash] Metadata hash (expanded into individual langfuse.observation.metadata.* attributes)
    def metadata=(value)
      update_observation_attributes(metadata: value)
    end

    # @param value [String] Level (DEBUG, DEFAULT, WARNING, ERROR)
    def level=(value)
      update_observation_attributes(level: value)
    end

    # @param name [String] Event name
    # @param input [Object, nil] Optional event data
    # @param level [String] Log level (debug, default, warning, error)
    #
    def event(name:, input: nil, level: "default")
      attributes = {
        "langfuse.observation.input" => input&.to_json,
        "langfuse.observation.level" => level
      }.compact

      @otel_span.add_event(name, attributes: attributes)
    end

    # @return [OpenTelemetry::SDK::Trace::Span]
    def current_span
      @otel_span
    end

    # Protected method used by subclasses' public `update` methods.
    #
    # @param attrs [Hash, Types::SpanAttributes, Types::GenerationAttributes] Attributes to update
    # @api private
    protected

    def update_observation_attributes(attrs = {}, **kwargs)
      # Don't set attributes on ended spans
      return unless @otel_span.recording?

      # Merge keyword arguments into attrs hash
      attrs_hash = if kwargs.any?
                     attrs.to_h.merge(kwargs)
                   else
                     attrs.to_h
                   end

      # Use @type instance variable set during initialization
      otel_attrs = OtelAttributes.create_observation_attributes(type, attrs_hash)
      otel_attrs.each { |key, value| @otel_span.set_attribute(key, value) }
    end

    # Converts a prompt object to hash format for OtelAttributes.
    #
    # @param prompt [Object, Hash, nil] Prompt object or hash
    # @return [Hash, Object, nil] Hash with name and version, or original prompt
    # @api protected
    def normalize_prompt(prompt)
      case prompt
      in obj if obj.respond_to?(:name) && obj.respond_to?(:version)
        { name: obj.name, version: obj.version }
      else
        prompt
      end
    end
  end

  # General-purpose observation for tracking operations, functions, or logical units of work.
  #
  # @example Block-based API
  #   Langfuse.observe("data-processing", input: { query: "test" }) do |span|
  #     result = process_data
  #     span.update(output: result, metadata: { duration_ms: 150 })
  #   end
  #
  # @example Stateful API
  #   span = Langfuse.start_observation("data-processing", input: { query: "test" })
  #   result = process_data
  #   span.update(output: result)
  #   span.end
  #
  class Span < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:span])
    end

    # @param attrs [Hash, Types::SpanAttributes] Span attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end
  end

  # Observation for LLM calls. Provides methods to set output, usage, and other LLM-specific metadata.
  #
  # @example Block-based API
  #   Langfuse.observe("chat-completion", as_type: :generation) do |gen|
  #     gen.model = "gpt-4"
  #     gen.input = [{ role: "user", content: "Hello" }]
  #     response = call_llm(gen.input)
  #     gen.output = response
  #     gen.usage = { prompt_tokens: 100, completion_tokens: 50, total_tokens: 150 }
  #   end
  #
  # @example Stateful API
  #   gen = Langfuse.start_observation("chat-completion", {
  #     model: "gpt-3.5-turbo",
  #     input: [{ role: "user", content: "Summarize this" }]
  #   }, as_type: :generation)
  #   response = call_llm(gen.input)
  #   gen.update(
  #     output: response,
  #     usage_details: { prompt_tokens: 50, completion_tokens: 25, total_tokens: 75 }
  #   )
  #   gen.end
  #
  class Generation < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:generation])
    end

    # @param attrs [Hash, Types::GenerationAttributes] Generation attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end

    # @param value [Hash] Usage hash with token counts (:prompt_tokens, :completion_tokens, :total_tokens)
    def usage=(value)
      return unless @otel_span.recording?

      # Convert to Langfuse API format (camelCase keys)
      usage_hash = {
        promptTokens: value[:prompt_tokens] || value["prompt_tokens"],
        completionTokens: value[:completion_tokens] || value["completion_tokens"],
        totalTokens: value[:total_tokens] || value["total_tokens"]
      }.compact

      usage_json = usage_hash.to_json
      @otel_span.set_attribute("langfuse.observation.usage", usage_json)
    end

    # @param value [String] Model name (e.g., "gpt-4", "claude-3-opus")
    def model=(value)
      return unless @otel_span.recording?

      @otel_span.set_attribute("langfuse.observation.model", value.to_s)
    end

    # @param value [Hash] Model parameters (temperature, max_tokens, etc.)
    def model_parameters=(value)
      return unless @otel_span.recording?

      # Convert to Langfuse API format (camelCase keys)
      params_hash = {}
      value.each do |k, v|
        key_str = k.to_s
        # Convert snake_case to camelCase
        camel_key = key_str.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }
        params_hash[camel_key] = v
      end
      params_json = params_hash.to_json
      @otel_span.set_attribute("langfuse.observation.modelParameters", params_json)
    end
  end

  # Point-in-time occurrence. Automatically ended when created without a block.
  #
  # @example Creating an event
  #   Langfuse.observe("user-action", as_type: :event) do |event|
  #     event.update(input: { action: "button_click", button_id: "submit" })
  #   end
  #
  # @example Event without block (auto-ends)
  #   event = Langfuse.start_observation("error-occurred", {
  #     input: { error: "Connection timeout" },
  #     level: "error"
  #   }, as_type: :event)
  #   # Event is automatically ended
  #
  class Event < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:event])
    end

    # @param attrs [Hash, Types::SpanAttributes] Event attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end
  end

  # Observation for tracking agent-based workflows that make decisions and use tools.
  #
  # @example Block-based API
  #   Langfuse.observe("agent-workflow", as_type: :agent) do |agent|
  #     agent.input = { task: "Find weather for NYC" }
  #     # Agent makes decisions and uses tools
  #     agent.start_observation("tool-call", { tool_name: "weather_api" }, as_type: :tool) do |tool|
  #       weather = fetch_weather("NYC")
  #       tool.update(output: weather)
  #     end
  #     agent.update(output: { result: "Sunny, 72°F" })
  #   end
  #
  # @example Stateful API
  #   agent = Langfuse.start_observation("agent-workflow", {
  #     input: { task: "Research topic" }
  #   }, as_type: :agent)
  #   # Agent logic here
  #   agent.update(output: { result: "Research complete" })
  #   agent.end
  #
  class Agent < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:agent])
    end

    # @param attrs [Hash, Types::AgentAttributes] Agent attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end
  end

  # Observation for tracking individual tool calls and external API interactions.
  #
  # @example Block-based API
  #   Langfuse.observe("api-call", as_type: :tool) do |tool|
  #     tool.input = { endpoint: "/users", method: "GET" }
  #     response = http_client.get("/users")
  #     tool.update(output: response.body, metadata: { status_code: response.status })
  #   end
  #
  # @example Stateful API
  #   tool = Langfuse.start_observation("database-query", {
  #     input: { query: "SELECT * FROM users" }
  #   }, as_type: :tool)
  #   results = db.execute(tool.input[:query])
  #   tool.update(output: results)
  #   tool.end
  #
  class Tool < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:tool])
    end

    # @param attrs [Hash, Types::ToolAttributes] Tool attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end
  end

  # Observation for tracking structured multi-step workflows and process chains.
  #
  # @example Block-based API
  #   Langfuse.observe("rag-pipeline", as_type: :chain) do |chain|
  #     chain.input = { query: "What is Ruby?" }
  #     # Step 1: Retrieve documents
  #     chain.start_observation("retrieve", { query: chain.input[:query] }, as_type: :retriever) do |ret|
  #       docs = vector_db.search(chain.input[:query])
  #       ret.update(output: docs)
  #     end
  #     # Step 2: Generate response
  #     chain.start_observation("generate", { model: "gpt-4" }, as_type: :generation) do |gen|
  #       response = llm.generate(docs)
  #       gen.update(output: response)
  #     end
  #     chain.update(output: { answer: "Ruby is a programming language..." })
  #   end
  #
  # @example Stateful API
  #   chain = Langfuse.start_observation("multi-step-process", {
  #     input: { data: "input_data" }
  #   }, as_type: :chain)
  #   # Chain steps here
  #   chain.update(output: { result: "processed_data" })
  #   chain.end
  #
  class Chain < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:chain])
    end

    # @param attrs [Hash, Types::ChainAttributes] Chain attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end
  end

  # Observation for tracking document retrieval and search operations.
  #
  # @example Block-based API
  #   Langfuse.observe("document-search", as_type: :retriever) do |retriever|
  #     retriever.input = { query: "Ruby programming", top_k: 5 }
  #     documents = vector_db.search(retriever.input[:query], limit: retriever.input[:top_k])
  #     retriever.update(
  #       output: documents,
  #       metadata: { num_results: documents.length, search_time_ms: 45 }
  #     )
  #   end
  #
  # @example Stateful API
  #   retriever = Langfuse.start_observation("semantic-search", {
  #     input: { query: "machine learning", top_k: 10 }
  #   }, as_type: :retriever)
  #   results = search_index.query(retriever.input[:query])
  #   retriever.update(output: results)
  #   retriever.end
  #
  class Retriever < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:retriever])
    end

    # @param attrs [Hash, Types::RetrieverAttributes] Retriever attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end
  end

  # Observation for tracking quality assessment and evaluation operations.
  #
  # @example Block-based API
  #   Langfuse.observe("quality-check", as_type: :evaluator) do |evaluator|
  #     evaluator.input = { response: "Ruby is a language", expected: "Ruby is a programming language" }
  #     score = calculate_similarity(evaluator.input[:response], evaluator.input[:expected])
  #     evaluator.update(
  #       output: { score: score, passed: score > 0.8 },
  #       metadata: { metric: "similarity" }
  #     )
  #   end
  #
  # @example Stateful API
  #   evaluator = Langfuse.start_observation("response-evaluation", {
  #     input: { response: llm_output, criteria: "accuracy" }
  #   }, as_type: :evaluator)
  #   evaluation_result = evaluate_response(evaluator.input[:response], evaluator.input[:criteria])
  #   evaluator.update(output: evaluation_result)
  #   evaluator.end
  #
  class Evaluator < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:evaluator])
    end

    # @param attrs [Hash, Types::EvaluatorAttributes] Evaluator attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end
  end

  # Observation for tracking safety checks and compliance enforcement.
  #
  # @example Block-based API
  #   Langfuse.observe("content-moderation", as_type: :guardrail) do |guardrail|
  #     guardrail.input = { content: user_input }
  #     result = moderation_service.check(guardrail.input[:content])
  #     guardrail.update(
  #       output: { passed: result.safe, reason: result.reason },
  #       metadata: { check_type: "toxicity" }
  #     )
  #   end
  #
  # @example Stateful API
  #   guardrail = Langfuse.start_observation("safety-check", {
  #     input: { prompt: user_prompt }
  #   }, as_type: :guardrail)
  #   safety_result = safety_service.validate(guardrail.input[:prompt])
  #   guardrail.update(output: { safe: safety_result.safe, violations: safety_result.violations })
  #   guardrail.end
  #
  class Guardrail < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:guardrail])
    end

    # @param attrs [Hash, Types::GuardrailAttributes] Guardrail attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end
  end

  # Observation for tracking embedding generation calls and vector operations.
  #
  # @example Block-based API
  #   Langfuse.observe("generate-embeddings", as_type: :embedding) do |embedding|
  #     embedding.model = "text-embedding-ada-002"
  #     embedding.input = ["Ruby is a language", "Python is a language"]
  #     vectors = embedding_service.generate(embedding.input, model: embedding.model)
  #     embedding.update(
  #       output: vectors,
  #       usage: { prompt_tokens: 20, total_tokens: 20 }
  #     )
  #   end
  #
  # @example Stateful API
  #   embedding = Langfuse.start_observation("vectorize", {
  #     model: "text-embedding-ada-002",
  #     input: "Convert this text to vector"
  #   }, as_type: :embedding)
  #   vector = embedding_api.create(embedding.input, model: embedding.model)
  #   embedding.update(
  #     output: vector,
  #     usage_details: { prompt_tokens: 10, total_tokens: 10 }
  #   )
  #   embedding.end
  #
  class Embedding < BaseObservation
    def initialize(otel_span, otel_tracer, attributes: nil)
      super(otel_span, otel_tracer, attributes: attributes, type: OBSERVATION_TYPES[:embedding])
    end

    # @param attrs [Hash, Types::EmbeddingAttributes] Embedding attributes to set
    # @return [self]
    def update(attrs)
      update_observation_attributes(attrs)
      self
    end

    # @param value [Hash] Usage hash with token counts (:prompt_tokens, :total_tokens)
    def usage=(value)
      update_observation_attributes(usage_details: value)
    end

    # @param value [String] Model name (e.g., "text-embedding-ada-002")
    def model=(value)
      update_observation_attributes(model: value)
    end

    # @param value [Hash] Model parameters (temperature, max_tokens, etc.)
    def model_parameters=(value)
      update_observation_attributes(model_parameters: value)
    end
  end
end
