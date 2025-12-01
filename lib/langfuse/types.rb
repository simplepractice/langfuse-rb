# frozen_string_literal: true

module Langfuse
  # Type definitions and constants for Langfuse domain models
  #
  # Provides observation type constants and attribute classes for type-safe
  # handling of Langfuse observations and traces.
  #
  # @example Using observation types
  #   Langfuse::Types::OBSERVATION_TYPES # => ["span", "generation", ...]
  #   Langfuse::Types::LEVELS # => ["DEBUG", "DEFAULT", "WARNING", "ERROR"]
  #
  # @example Using attribute classes
  #   attrs = Langfuse::Types::SpanAttributes.new(
  #     input: { query: "test" },
  #     level: "DEFAULT",
  #     metadata: { source: "api" }
  #   )
  #   attrs.to_h # => { input: {...}, level: "DEFAULT", metadata: {...} }
  #
  module Types
    # Types of observations that can be created in Langfuse
    #
    # - `span`: General-purpose observations for tracking operations, functions, or logical units of work
    # - `generation`: Specialized observations for LLM calls with model parameters, usage, and costs
    # - `event`: Point-in-time occurrences or log entries within a trace
    # - `embedding`: Observations for embedding generation calls
    # - `agent`: Observations for agent-based workflows
    # - `tool`: Observations for tool/function calls
    # - `chain`: Observations for chain-based workflows
    # - `retriever`: Observations for retrieval operations
    # - `evaluator`: Observations for evaluation operations
    # - `guardrail`: Observations for guardrail checks
    #
    # @return [Array<String>] Array of observation type strings
    OBSERVATION_TYPES = %w[
      span generation event embedding
      agent tool chain retriever
      evaluator guardrail
    ].freeze

    # Severity levels for observations in Langfuse
    #
    # Used to categorize the importance or severity of observations:
    # - `DEBUG`: Detailed diagnostic information
    # - `DEFAULT`: Normal operation information
    # - `WARNING`: Potentially problematic situations
    # - `ERROR`: Error conditions that need attention
    #
    # @return [Array<String>] Array of level strings
    LEVELS = %w[DEBUG DEFAULT WARNING ERROR].freeze

    # Data types for Langfuse scores
    #
    # Used to categorize score values:
    # - `numeric`: Numeric values (Integer, Float, BigDecimal)
    # - `boolean`: Boolean values (true/false or 0/1)
    # - `categorical`: String values for categorical scores
    #
    # @return [Hash<Symbol, String>] Hash mapping symbol keys to API string values
    SCORE_DATA_TYPES = {
      numeric: "NUMERIC",
      boolean: "BOOLEAN",
      categorical: "CATEGORICAL"
    }.freeze

    # Valid score data type symbols
    #
    # @return [Array<Symbol>] Array of valid data type symbols
    VALID_SCORE_DATA_TYPES = SCORE_DATA_TYPES.keys.freeze

    # Attributes for Langfuse span observations
    #
    # Spans are used to track operations, functions, or logical units of work.
    # They can contain other spans, generations, or events as children.
    #
    # @example
    #   attrs = SpanAttributes.new(
    #     input: { query: "SELECT * FROM users" },
    #     output: { count: 42 },
    #     level: "DEFAULT",
    #     metadata: { source: "database" }
    #   )
    #   attrs.to_h # => { input: {...}, output: {...}, level: "DEFAULT", metadata: {...} }
    #
    class SpanAttributes
      # @return [Object, nil] Input data for the operation being tracked
      attr_accessor :input

      # @return [Object, nil] Output data from the operation
      attr_accessor :output

      # @return [Hash, nil] Additional metadata as key-value pairs
      attr_accessor :metadata

      # @return [String, nil] Severity level of the observation (DEBUG, DEFAULT, WARNING, ERROR)
      attr_accessor :level

      # @return [String, nil] Human-readable status message
      attr_accessor :status_message

      # @return [String, nil] Version identifier for the code/model being tracked
      attr_accessor :version

      # @return [String, nil] Environment where the operation is running (e.g., 'production', 'staging')
      attr_accessor :environment

      # Initialize a new SpanAttributes instance
      #
      # @param input [Object, nil] Input data for the operation
      # @param output [Object, nil] Output data from the operation
      # @param metadata [Hash, nil] Additional metadata as key-value pairs
      # @param level [String, nil] Severity level (DEBUG, DEFAULT, WARNING, ERROR)
      # @param status_message [String, nil] Human-readable status message
      # @param version [String, nil] Version identifier
      # @param environment [String, nil] Environment identifier
      # rubocop:disable Metrics/ParameterLists
      def initialize(input: nil, output: nil, metadata: nil, level: nil, status_message: nil, version: nil,
                     environment: nil)
        # rubocop:enable Metrics/ParameterLists
        @input = input
        @output = output
        @metadata = metadata
        @level = level
        @status_message = status_message
        @version = version
        @environment = environment
      end

      # Convert attributes to a hash representation
      #
      # Returns a hash with all non-nil attributes. Nil values are excluded.
      #
      # @return [Hash] Hash representation of attributes
      def to_h
        {
          input: @input,
          output: @output,
          metadata: @metadata,
          level: @level,
          status_message: @status_message,
          version: @version,
          environment: @environment
        }.compact
      end
    end

    # Attributes for Langfuse generation observations
    #
    # Generations are specialized observations for tracking LLM interactions,
    # including model parameters, usage metrics, costs, and prompt information.
    #
    # @example
    #   attrs = GenerationAttributes.new(
    #     model: "gpt-4",
    #     input: { messages: [...] },
    #     output: { content: "Hello!" },
    #     model_parameters: { temperature: 0.7 },
    #     usage_details: { prompt_tokens: 100, completion_tokens: 50 },
    #     prompt: { name: "greeting", version: 1, is_fallback: false }
    #   )
    #
    class GenerationAttributes < SpanAttributes
      # @return [Time, nil] Timestamp when the model started generating completion
      attr_accessor :completion_start_time

      # @return [String, nil] Name of the language model used (e.g., 'gpt-4', 'claude-3-opus')
      attr_accessor :model

      # @return [Hash, nil] Parameters passed to the model (temperature, max_tokens, etc.)
      attr_accessor :model_parameters

      # @return [Hash, nil] Token usage and other model-specific usage metrics
      attr_accessor :usage_details

      # @return [Hash, nil] Cost breakdown for the generation (total_cost, etc.)
      attr_accessor :cost_details

      # @return [Hash, nil] Information about the prompt used from Langfuse prompt management
      #   Hash should contain :name (String), :version (Integer), :is_fallback (Boolean)
      attr_accessor :prompt

      # Initialize a new GenerationAttributes instance
      #
      # @param completion_start_time [Time, nil] Timestamp when completion started
      # @param model [String, nil] Model name
      # @param model_parameters [Hash, nil] Model parameters
      # @param usage_details [Hash, nil] Usage metrics
      # @param cost_details [Hash, nil] Cost breakdown
      # @param prompt [Hash, nil] Prompt information with :name, :version, :is_fallback keys
      # @param kwargs [Hash] Additional keyword arguments passed to SpanAttributes
      # rubocop:disable Metrics/ParameterLists
      def initialize(completion_start_time: nil, model: nil, model_parameters: nil, usage_details: nil,
                     cost_details: nil, prompt: nil, **)
        # rubocop:enable Metrics/ParameterLists
        super(**)
        @completion_start_time = completion_start_time
        @model = model
        @model_parameters = model_parameters
        @usage_details = usage_details
        @cost_details = cost_details
        @prompt = prompt
      end

      # Convert attributes to a hash representation
      #
      # Returns a hash with all non-nil attributes, including both span and generation-specific fields.
      #
      # @return [Hash] Hash representation of attributes
      def to_h
        super.merge(
          completion_start_time: @completion_start_time,
          model: @model,
          model_parameters: @model_parameters,
          usage_details: @usage_details,
          cost_details: @cost_details,
          prompt: @prompt
        ).compact
      end
    end

    # Attributes for Langfuse embedding observations
    #
    # Embeddings are specialized observations for tracking embedding generation calls.
    # They extend GenerationAttributes to include all generation-specific fields.
    #
    class EmbeddingAttributes < GenerationAttributes
    end

    # Attributes for Langfuse traces
    #
    # Traces are the top-level containers that group related observations together.
    # They represent a complete workflow, request, or user interaction.
    #
    # @example
    #   attrs = TraceAttributes.new(
    #     name: "user-request",
    #     user_id: "user-123",
    #     session_id: "session-456",
    #     input: { query: "What is Ruby?" },
    #     output: { answer: "Ruby is a programming language" },
    #     tags: ["api", "v1"],
    #     public: false
    #   )
    #
    class TraceAttributes
      # @return [String, nil] Human-readable name for the trace
      attr_accessor :name

      # @return [String, nil] Identifier for the user associated with this trace
      attr_accessor :user_id

      # @return [String, nil] Session identifier for grouping related traces
      attr_accessor :session_id

      # @return [String, nil] Version identifier for the code/application
      attr_accessor :version

      # @return [String, nil] Release identifier for deployment tracking
      attr_accessor :release

      # @return [Object, nil] Input data that initiated the trace
      attr_accessor :input

      # @return [Object, nil] Final output data from the trace
      attr_accessor :output

      # @return [Hash, nil] Additional metadata for the trace
      attr_accessor :metadata

      # @return [Array<String>, nil] Tags for categorizing and filtering traces
      attr_accessor :tags

      # @return [Boolean, nil] Whether this trace should be publicly visible
      attr_accessor :public

      # @return [String, nil] Environment where the trace was captured
      attr_accessor :environment

      # Initialize a new TraceAttributes instance
      #
      # @param name [String, nil] Human-readable name for the trace
      # @param user_id [String, nil] User identifier
      # @param session_id [String, nil] Session identifier
      # @param version [String, nil] Version identifier
      # @param release [String, nil] Release identifier
      # @param input [Object, nil] Input data
      # @param output [Object, nil] Output data
      # @param metadata [Hash, nil] Additional metadata
      # @param tags [Array<String>, nil] Tags array
      # @param public [Boolean, nil] Public visibility flag
      # @param environment [String, nil] Environment identifier
      # rubocop:disable Metrics/ParameterLists
      def initialize(name: nil, user_id: nil, session_id: nil, version: nil, release: nil, input: nil, output: nil,
                     metadata: nil, tags: nil, public: nil, environment: nil)
        # rubocop:enable Metrics/ParameterLists
        @name = name
        @user_id = user_id
        @session_id = session_id
        @version = version
        @release = release
        @input = input
        @output = output
        @metadata = metadata
        @tags = tags
        @public = public
        @environment = environment
      end

      # Convert attributes to a hash representation
      #
      # Returns a hash with all non-nil attributes. Nil values are excluded.
      #
      # @return [Hash] Hash representation of attributes
      def to_h
        {
          name: @name,
          user_id: @user_id,
          session_id: @session_id,
          version: @version,
          release: @release,
          input: @input,
          output: @output,
          metadata: @metadata,
          tags: @tags,
          public: @public,
          environment: @environment
        }.compact
      end
    end

    # Alias for event observation attributes (same as SpanAttributes)
    EventAttributes = SpanAttributes

    # Alias for agent observation attributes (same as SpanAttributes)
    AgentAttributes = SpanAttributes

    # Alias for tool observation attributes (same as SpanAttributes)
    ToolAttributes = SpanAttributes

    # Alias for chain observation attributes (same as SpanAttributes)
    ChainAttributes = SpanAttributes

    # Alias for retriever observation attributes (same as SpanAttributes)
    RetrieverAttributes = SpanAttributes

    # Alias for evaluator observation attributes (same as SpanAttributes)
    EvaluatorAttributes = SpanAttributes

    # Alias for guardrail observation attributes (same as SpanAttributes)
    GuardrailAttributes = SpanAttributes
  end
end
