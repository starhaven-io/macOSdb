# frozen_string_literal: true
require_relative "test_helper"

class CIConclusionTests < Minitest::Test
  include WorkflowHelpers

  def setup
    @script = workflow_run_block(CI_WORKFLOW.read, "Result")
    @environment = {
      "GITHUB_EVENT_NAME" => "pull_request", "GENERATE_MATRIX_RESULT" => "success",
      "COMMITS_RESULT" => "success", "CHECK_RESULT" => "success", "CODEQL_RESULT" => "success",
      "CODEQL_INTERPRETED_RESULT" => "success", "ZIZMOR_RESULT" => "success", "PINPRICK_RESULT" => "success",
      "LINKS_RESULT" => "success", "CODECOV_RESULT" => "success", "MATRIX" => '[{"check":"test-tsan"}]',
      "RUN_CODEQL" => "true", "RUN_CODEQL_INTERPRETED" => "true", "RUN_ZIZMOR" => "true",
      "RUN_LINKS" => "true", "RUN_CODECOV" => "true", "UPLOAD_ALLOWED" => "true"
    }
  end

  def conclude(overrides = {}) = bash(@script, env: @environment.merge(overrides))

  def test_required_results_cannot_be_skipped_or_unsuccessful
    assert conclude.success?
    @environment.keys.grep(/_RESULT\z/).each do |name|
      ["skipped", "failure", "cancelled", "timed_out", ""].each do |result|
        refute conclude(name => result).success?, "#{name}: #{result}"
      end
    end
  end

  def test_only_unselected_routes_may_be_skipped
    { "RUN_CODEQL" => %w[CODEQL_RESULT], "RUN_CODEQL_INTERPRETED" => %w[CODEQL_INTERPRETED_RESULT],
      "RUN_ZIZMOR" => %w[ZIZMOR_RESULT PINPRICK_RESULT], "RUN_LINKS" => %w[LINKS_RESULT],
      "RUN_CODECOV" => %w[CODECOV_RESULT] }.each do |route, results|
      skipped = results.to_h { |result| [result, "skipped"] }.merge(route => "false")
      assert conclude(skipped).success?, route
      results.each { |result| refute conclude(skipped.merge(result => "failure")).success? }
      refute conclude(route => "").success?
    end
    assert conclude("MATRIX" => "[]", "CHECK_RESULT" => "skipped").success?
    refute conclude("MATRIX" => "").success?
  end

  def test_push_and_fork_upload_exceptions_preserve_source_requirements
    assert conclude("GITHUB_EVENT_NAME" => "push", "COMMITS_RESULT" => "skipped").success?
    assert conclude("UPLOAD_ALLOWED" => "false", "CODECOV_RESULT" => "skipped").success?
    refute conclude("UPLOAD_ALLOWED" => "false", "CODECOV_RESULT" => "skipped", "CHECK_RESULT" => "skipped").success?
    refute conclude("UPLOAD_ALLOWED" => "").success?
    refute conclude("GITHUB_EVENT_NAME" => "workflow_dispatch").success?
  end
end
