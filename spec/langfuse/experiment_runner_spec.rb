# frozen_string_literal: true

RSpec.describe Langfuse::ExperimentRunner do
  let(:mock_client) { instance_double(Langfuse::Client) }
  let(:logger) { instance_double(Logger, warn: nil, error: nil, info: nil, debug: nil) }

  before do
    allow(mock_client).to receive(:create_dataset_run_item)
    allow(mock_client).to receive(:create_score)
    allow(mock_client).to receive(:flush_scores)
    allow(Langfuse).to receive(:force_flush)
    allow(Langfuse.configuration).to receive(:logger).and_return(logger)
  end

  describe "#execute" do
    context "with local data items" do
      let(:items) do
        [
          { input: "What is 2+2?", expected_output: "4" },
          { input: "What is 3+3?", expected_output: "6" }
        ]
      end

      it "runs task for each item" do
        called_with = []
        task = lambda { |item|
          called_with << item
          "answer"
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: task
        )
        runner.execute

        expect(called_with.size).to eq(2)
        expect(called_with).to all(be_a(Langfuse::ExperimentItem))
      end

      it "returns ExperimentResult with correct name" do
        runner = described_class.new(
          client: mock_client, name: "my-exp", items: items, task: ->(_) { "a" }
        )
        result = runner.execute

        expect(result).to be_a(Langfuse::ExperimentResult)
        expect(result.name).to eq("my-exp")
      end

      it "generates run_name from name and timestamp by default" do
        runner = described_class.new(
          client: mock_client, name: "my-exp", items: items, task: ->(_) { "a" }
        )
        result = runner.execute

        expect(result.run_name).to match(/\Amy-exp - \d{4}-\d{2}-\d{2}T/)
      end

      it "uses explicit run_name when provided" do
        runner = described_class.new(
          client: mock_client, name: "my-exp", items: items,
          task: ->(_) { "a" }, run_name: "custom-run"
        )
        result = runner.execute

        expect(result.run_name).to eq("custom-run")
      end

      it "passes description through to ExperimentResult" do
        runner = described_class.new(
          client: mock_client, name: "my-exp", items: items,
          task: ->(_) { "a" }, description: "my description"
        )
        result = runner.execute

        expect(result.description).to eq("my description")
      end

      it "returns item_results for each item" do
        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: ->(_) { "a" }
        )
        result = runner.execute

        expect(result.item_results.size).to eq(2)
        expect(result.item_results).to all(be_a(Langfuse::ItemResult))
      end

      it "captures task output in item_results" do
        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(item) { "answer-#{item.input}" }
        )
        result = runner.execute

        expect(result.item_results.first.output).to eq("answer-What is 2+2?")
      end

      it "does not link local data items to dataset runs" do
        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: ->(_) { "a" }
        )
        runner.execute

        expect(mock_client).not_to have_received(:create_dataset_run_item)
      end

      it "sets trace_id on item results" do
        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: ->(_) { "a" }
        )
        result = runner.execute

        result.item_results.each do |ir|
          expect(ir.trace_id).to be_a(String)
          expect(ir.trace_id.length).to eq(32)
        end
      end

      it "sets observation_id on item results" do
        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: ->(_) { "a" }
        )
        result = runner.execute

        result.item_results.each do |ir|
          expect(ir.observation_id).to be_a(String)
          expect(ir.observation_id.length).to eq(16)
        end
      end

      it "normalizes hash items into ExperimentItem objects" do
        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: ->(_) { "a" }
        )
        result = runner.execute

        result.item_results.each do |ir|
          expect(ir.item).to be_a(Langfuse::ExperimentItem)
          expect(ir.item).to respond_to(:input)
          expect(ir.item).to respond_to(:expected_output)
        end
        expect(result.item_results.first.item.input).to eq("What is 2+2?")
      end

      it "supports local data items with string keys" do
        string_key_items = [
          { "input" => "What is 5+5?", "expected_output" => "10" }
        ]
        runner = described_class.new(
          client: mock_client, name: "test", items: string_key_items,
          task: ->(item) { "answer-#{item.input}" }
        )
        result = runner.execute

        expect(result.item_results.size).to eq(1)
        expect(result.item_results.first.item.input).to eq("What is 5+5?")
        expect(result.item_results.first.item.expected_output).to eq("10")
        expect(result.item_results.first.output).to eq("answer-What is 5+5?")
      end

      it "extracts metadata from local data items" do
        items_with_meta = [
          { input: "q1", expected_output: "a1", metadata: { difficulty: "easy" } }
        ]
        runner = described_class.new(
          client: mock_client, name: "test", items: items_with_meta, task: ->(_) { "a" }
        )
        result = runner.execute

        expect(result.item_results.first.item.metadata).to eq({ difficulty: "easy" })
      end
    end

    context "with dataset items" do
      let(:dataset_items) do
        [
          Langfuse::DatasetItemClient.new(
            { "id" => "item-1", "datasetId" => "ds-1",
              "input" => { "q" => "test1" }, "expectedOutput" => "a1" },
            client: mock_client
          ),
          Langfuse::DatasetItemClient.new(
            { "id" => "item-2", "datasetId" => "ds-1",
              "input" => { "q" => "test2" }, "expectedOutput" => "a2" },
            client: mock_client
          )
        ]
      end

      it "links dataset items via create_dataset_run_item with run_name" do
        runner = described_class.new(
          client: mock_client, name: "ds-exp", items: dataset_items,
          task: ->(_) { "a" }, run_name: "ds-exp - 2025-01-01T00:00:00Z"
        )
        runner.execute

        expect(mock_client).to have_received(:create_dataset_run_item).twice
        expect(mock_client).to have_received(:create_dataset_run_item).with(
          hash_including(dataset_item_id: "item-1", run_name: "ds-exp - 2025-01-01T00:00:00Z")
        )
        expect(mock_client).to have_received(:create_dataset_run_item).with(
          hash_including(dataset_item_id: "item-2", run_name: "ds-exp - 2025-01-01T00:00:00Z")
        )
      end

      it "passes description as run_description" do
        runner = described_class.new(
          client: mock_client, name: "ds-exp", items: dataset_items,
          task: ->(_) { "a" }, description: "test run desc"
        )
        runner.execute

        expect(mock_client).to have_received(:create_dataset_run_item).with(
          hash_including(run_description: "test run desc")
        ).twice
      end

      it "passes observation_id in dataset run item linking" do
        runner = described_class.new(
          client: mock_client, name: "ds-exp", items: dataset_items,
          task: ->(_) { "a" }
        )
        runner.execute

        expect(mock_client).to have_received(:create_dataset_run_item).with(
          hash_including(observation_id: a_string_matching(/\A[0-9a-f]{16}\z/))
        ).twice
      end

      it "passes metadata in dataset run item linking" do
        runner = described_class.new(
          client: mock_client, name: "ds-exp", items: dataset_items,
          task: ->(_) { "a" }, metadata: { env: "test" }
        )
        runner.execute

        expect(mock_client).to have_received(:create_dataset_run_item).with(
          hash_including(metadata: { env: "test" })
        ).twice
      end

      it "captures dataset_run_id from linking response" do
        allow(mock_client).to receive(:create_dataset_run_item)
          .and_return({ "datasetRunId" => "run-abc-123" })

        runner = described_class.new(
          client: mock_client, name: "ds-exp", items: dataset_items,
          task: ->(_) { "a" }
        )
        result = runner.execute

        expect(result.dataset_run_id).to eq("run-abc-123")
      end
    end

    context "when task fails" do
      let(:items) do
        [
          { input: "q1", expected_output: "a1" },
          { input: "q2", expected_output: "a2" }
        ]
      end

      it "isolates errors - other items still run" do
        call_count = 0
        task = lambda { |item|
          call_count += 1
          raise StandardError, "boom" if item.input == "q1"

          "answer"
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: task
        )
        result = runner.execute

        expect(call_count).to eq(2)
        expect(result.item_results.size).to eq(2)
        expect(result.successes.size).to eq(1)
        expect(result.failures.size).to eq(1)
        expect(result.failures.first.error.message).to eq("boom")
        expect(result.successes.first.item.input).to eq("q2")
        expect(logger).to have_received(:warn).with(/Task failed/)
      end

      it "includes failed items in item_results" do
        task = ->(_) { raise StandardError, "task error" }
        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: task
        )
        result = runner.execute

        expect(result.item_results.size).to eq(2)
        expect(result.failures.size).to eq(2)
        expect(result.successes).to eq([])
        result.item_results.each do |ir|
          expect(ir.failed?).to be true
          expect(ir.error).to be_a(StandardError)
        end
      end

      it "does not run evaluators for failed items" do
        evaluator_called = false
        evaluator = lambda { |**_kwargs|
          evaluator_called = true
          Langfuse::Evaluation.new(name: "s", value: 1.0)
        }
        task = ->(_) { raise StandardError, "boom" }

        runner = described_class.new(
          client: mock_client, name: "test", items: [items.first],
          task: task, evaluators: [evaluator]
        )
        runner.execute

        expect(evaluator_called).to be false
      end

      it "still sets observation_id on failed items" do
        task = ->(_) { raise StandardError, "boom" }
        runner = described_class.new(
          client: mock_client, name: "test", items: [items.first], task: task
        )
        result = runner.execute

        expect(result.failures.first.observation_id).to be_a(String)
      end
    end

    context "with evaluators" do
      let(:items) { [{ input: "q1", expected_output: "a1" }] }

      it "runs evaluators and collects evaluations" do
        evaluator = lambda { |output:, expected_output:, **|
          Langfuse::Evaluation.new(
            name: "exact_match",
            value: output == expected_output ? 1.0 : 0.0
          )
        }
        task = ->(_) { "a1" }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: task, evaluators: [evaluator]
        )
        result = runner.execute

        expect(result.item_results.first.evaluations.size).to eq(1)
        expect(result.item_results.first.evaluations.first.name).to eq("exact_match")
        expect(result.item_results.first.evaluations.first.value).to eq(1.0)
      end

      it "supports evaluators returning arrays of evaluations" do
        evaluator = lambda { |**|
          [
            Langfuse::Evaluation.new(name: "accuracy", value: 1.0),
            Langfuse::Evaluation.new(name: "relevance", value: 0.75)
          ]
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a1" }, evaluators: [evaluator]
        )
        result = runner.execute

        names = result.item_results.first.evaluations.map(&:name)
        expect(names).to contain_exactly("accuracy", "relevance")
        expect(mock_client).to have_received(:create_score).with(
          hash_including(name: "accuracy", value: 1.0)
        )
        expect(mock_client).to have_received(:create_score).with(
          hash_including(name: "relevance", value: 0.75)
        )
      end

      it "supports evaluators returning hashes" do
        evaluator = lambda { |**|
          { name: "hash_score", value: 0.9, comment: "from hash" }
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a1" }, evaluators: [evaluator]
        )
        result = runner.execute

        eval = result.item_results.first.evaluations.first
        expect(eval.name).to eq("hash_score")
        expect(eval.value).to eq(0.9)
        expect(eval.comment).to eq("from hash")
      end

      it "supports evaluators returning arrays of hashes" do
        evaluator = lambda { |**|
          [
            { name: "s1", value: 1.0 },
            { name: "s2", value: 0.5 }
          ]
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a1" }, evaluators: [evaluator]
        )
        result = runner.execute

        names = result.item_results.first.evaluations.map(&:name)
        expect(names).to contain_exactly("s1", "s2")
      end

      it "supports hash evaluator results with string keys" do
        evaluator = lambda { |**|
          { "name" => "str_keys", "value" => 0.8 }
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a1" }, evaluators: [evaluator]
        )
        result = runner.execute

        expect(result.item_results.first.evaluations.first.name).to eq("str_keys")
      end

      it "persists scores via client" do
        evaluator = lambda { |**|
          Langfuse::Evaluation.new(name: "score", value: 0.9)
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, evaluators: [evaluator]
        )
        runner.execute

        expect(mock_client).to have_received(:create_score).with(
          hash_including(name: "score", value: 0.9)
        )
      end

      it "persists config_id and metadata from evaluations" do
        evaluator = lambda { |**|
          Langfuse::Evaluation.new(
            name: "score", value: 0.9,
            config_id: "cfg-1", metadata: { k: "v" }
          )
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, evaluators: [evaluator]
        )
        runner.execute

        expect(mock_client).to have_received(:create_score).with(
          hash_including(config_id: "cfg-1", metadata: { k: "v" })
        )
      end

      it "silently drops failed evaluators" do
        bad_evaluator = ->(**) { raise StandardError, "eval error" }
        good_evaluator = ->(**) { Langfuse::Evaluation.new(name: "good", value: 1.0) }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, evaluators: [bad_evaluator, good_evaluator]
        )
        result = runner.execute

        expect(result.item_results.first.success?).to be true
        expect(result.item_results.first.evaluations.size).to eq(1)
        expect(result.item_results.first.evaluations.first.name).to eq("good")
      end

      it "filters out nil evaluator returns" do
        nil_evaluator = ->(**) {}
        good_evaluator = ->(**) { Langfuse::Evaluation.new(name: "good", value: 1.0) }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, evaluators: [nil_evaluator, good_evaluator]
        )
        result = runner.execute

        expect(result.item_results.first.evaluations.size).to eq(1)
      end

      it "drops unsupported evaluator return types" do
        bad_type = ->(**) { "not an evaluation" }
        good_evaluator = ->(**) { Langfuse::Evaluation.new(name: "good", value: 1.0) }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, evaluators: [bad_type, good_evaluator]
        )
        result = runner.execute

        expect(result.item_results.first.evaluations.size).to eq(1)
        expect(result.item_results.first.evaluations.first.name).to eq("good")
        expect(logger).to have_received(:warn).with(/unsupported result type/)
      end

      context "with metadata: kwarg support" do
        let(:dataset_item) do
          Langfuse::DatasetItemClient.new(
            { "id" => "item-1", "datasetId" => "ds-1",
              "input" => { "q" => "test" }, "expectedOutput" => "a1",
              "metadata" => { "difficulty" => "easy" } },
            client: mock_client
          )
        end

        it "passes metadata to evaluators that accept it" do
          received_metadata = nil
          evaluator = lambda { |metadata:, **|
            received_metadata = metadata
            Langfuse::Evaluation.new(name: "s", value: 1.0)
          }

          runner = described_class.new(
            client: mock_client, name: "test", items: [dataset_item],
            task: ->(_) { "a" }, evaluators: [evaluator]
          )
          runner.execute

          expect(received_metadata).to eq({ "difficulty" => "easy" })
        end

        it "does not pass metadata to evaluators that do not accept it" do
          received_keys = nil
          evaluator = lambda { |**kwargs|
            received_keys = kwargs.keys
            Langfuse::Evaluation.new(name: "s", value: 1.0)
          }

          runner = described_class.new(
            client: mock_client, name: "test", items: [dataset_item],
            task: ->(_) { "a" }, evaluators: [evaluator]
          )
          runner.execute

          expect(received_keys).not_to include(:metadata)
        end
      end
    end

    context "when score persistence fails" do
      let(:items) { [{ input: "q1", expected_output: "a1" }] }

      it "logs warning and continues" do
        allow(mock_client).to receive(:create_score).and_raise(StandardError, "score error")
        evaluator = ->(**) { Langfuse::Evaluation.new(name: "s", value: 1.0) }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, evaluators: [evaluator]
        )
        result = runner.execute

        expect(result.item_results.first.success?).to be true
        expect(logger).to have_received(:warn).with(/Score persistence failed/)
      end
    end

    context "with run evaluators" do
      let(:items) { [{ input: "q1" }, { input: "q2" }] }

      it "receives all item_results" do
        received_results = nil
        run_evaluator = lambda { |item_results:|
          received_results = item_results
          Langfuse::Evaluation.new(name: "avg", value: 1.0)
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, run_evaluators: [run_evaluator]
        )
        runner.execute

        expect(received_results.size).to eq(2)
        expect(received_results).to all(be_a(Langfuse::ItemResult))
      end

      it "includes run_evaluations in result" do
        run_evaluator = lambda { |item_results:| # rubocop:disable Lint/UnusedBlockArgument
          Langfuse::Evaluation.new(name: "avg_score", value: 0.85)
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, run_evaluators: [run_evaluator]
        )
        result = runner.execute

        expect(result.run_evaluations.size).to eq(1)
        expect(result.run_evaluations.first.name).to eq("avg_score")
      end

      it "supports run evaluators returning arrays" do
        run_evaluator = lambda { |item_results:| # rubocop:disable Lint/UnusedBlockArgument
          [
            Langfuse::Evaluation.new(name: "avg_score", value: 0.85),
            Langfuse::Evaluation.new(name: "success_rate", value: 1.0)
          ]
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, run_evaluators: [run_evaluator]
        )
        result = runner.execute

        names = result.run_evaluations.map(&:name)
        expect(names).to contain_exactly("avg_score", "success_rate")
      end

      it "supports run evaluators returning hashes" do
        run_evaluator = lambda { |item_results:| # rubocop:disable Lint/UnusedBlockArgument
          { name: "avg_score", value: 0.85 }
        }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, run_evaluators: [run_evaluator]
        )
        result = runner.execute

        expect(result.run_evaluations.first.name).to eq("avg_score")
      end

      it "silently drops failed run evaluators" do
        bad_run_eval = ->(**) { raise StandardError, "run eval error" }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, run_evaluators: [bad_run_eval]
        )
        result = runner.execute

        expect(result.run_evaluations).to eq([])
        expect(logger).to have_received(:warn).with(/Run evaluator failed/)
      end

      it "drops unsupported run evaluator return types" do
        bad_run_eval = ->(**) { "invalid" }
        good_run_eval = ->(**) { Langfuse::Evaluation.new(name: "avg", value: 1.0) }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, run_evaluators: [bad_run_eval, good_run_eval]
        )
        result = runner.execute

        expect(result.run_evaluations.map(&:name)).to eq(["avg"])
        expect(logger).to have_received(:warn).with(/unsupported result type/)
      end

      context "with dataset_run_id captured" do
        let(:dataset_items) do
          [
            Langfuse::DatasetItemClient.new(
              { "id" => "item-1", "datasetId" => "ds-1",
                "input" => { "q" => "test" }, "expectedOutput" => "a1" },
              client: mock_client
            )
          ]
        end

        it "persists run evaluations as scores with dataset_run_id" do
          allow(mock_client).to receive(:create_dataset_run_item)
            .and_return({ "datasetRunId" => "run-xyz" })

          run_evaluator = lambda { |item_results:| # rubocop:disable Lint/UnusedBlockArgument
            Langfuse::Evaluation.new(name: "avg_score", value: 0.85)
          }

          runner = described_class.new(
            client: mock_client, name: "test", items: dataset_items,
            task: ->(_) { "a" }, run_evaluators: [run_evaluator]
          )
          runner.execute

          expect(mock_client).to have_received(:create_score).with(
            hash_including(name: "avg_score", value: 0.85, dataset_run_id: "run-xyz")
          )
        end

        it "logs warning when run score persistence fails" do
          allow(mock_client).to receive(:create_dataset_run_item)
            .and_return({ "datasetRunId" => "run-xyz" })
          allow(mock_client).to receive(:create_score).and_raise(StandardError, "score fail")

          run_evaluator = lambda { |item_results:| # rubocop:disable Lint/UnusedBlockArgument
            Langfuse::Evaluation.new(name: "avg", value: 1.0)
          }

          runner = described_class.new(
            client: mock_client, name: "test", items: dataset_items,
            task: ->(_) { "a" }, run_evaluators: [run_evaluator]
          )
          runner.execute

          expect(logger).to have_received(:warn).with(/Run score persistence failed/)
        end
      end

      context "without dataset_run_id" do
        it "does not persist run evaluations as scores" do
          run_evaluator = lambda { |item_results:| # rubocop:disable Lint/UnusedBlockArgument
            Langfuse::Evaluation.new(name: "avg", value: 1.0)
          }

          runner = described_class.new(
            client: mock_client, name: "test", items: items,
            task: ->(_) { "a" }, run_evaluators: [run_evaluator]
          )
          runner.execute

          expect(mock_client).not_to have_received(:create_score)
        end
      end
    end

    context "when flushing" do
      let(:items) { [{ input: "q1" }, { input: "q2" }, { input: "q3" }] }

      it "flushes scores only at end of execute, not per-item" do
        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: ->(_) { "a" }
        )
        runner.execute

        # Only the final flush_all call, not once per item
        expect(mock_client).to have_received(:flush_scores).once
      end

      it "calls force_flush only at end of execute, not per-item" do
        runner = described_class.new(
          client: mock_client, name: "test", items: items, task: ->(_) { "a" }
        )
        runner.execute

        # Only the final flush_all call, not once per item
        expect(Langfuse).to have_received(:force_flush).once
      end

      it "flushes again after run evaluators produce results" do
        run_evaluator = ->(**) { Langfuse::Evaluation.new(name: "avg", value: 1.0) }

        runner = described_class.new(
          client: mock_client, name: "test", items: items,
          task: ->(_) { "a" }, run_evaluators: [run_evaluator]
        )
        runner.execute

        # Once for post-items flush_all, once for post-run-evaluators flush_all
        expect(mock_client).to have_received(:flush_scores).twice
        expect(Langfuse).to have_received(:force_flush).twice
      end
    end

    context "when dataset linking fails" do
      let(:dataset_item) do
        Langfuse::DatasetItemClient.new(
          { "id" => "item-1", "datasetId" => "ds-1",
            "input" => { "q" => "test" }, "expectedOutput" => "a1" },
          client: mock_client
        )
      end

      it "logs warning and continues" do
        allow(mock_client).to receive(:create_dataset_run_item)
          .and_raise(StandardError, "link error")

        runner = described_class.new(
          client: mock_client, name: "test", items: [dataset_item], task: ->(_) { "a" }
        )
        result = runner.execute

        expect(result.item_results.first.success?).to be true
        expect(logger).to have_received(:warn).with(/Dataset run item linking failed/)
      end
    end
  end
end
