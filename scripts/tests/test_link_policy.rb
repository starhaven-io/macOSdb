# frozen_string_literal: true
require_relative "test_helper"

class LinkPolicyTests < Minitest::Test
  include WorkflowHelpers

  def test_release_links_resolve_to_built_files_and_missing_pages_fail
    skip "link-checker integration requires lychee; just check requires this tool" unless system("command -v lychee >/dev/null")
    links = CI_WORKFLOW.read.split("  links:\n", 2).last.split("\n  conclusion:", 2).first
    args = JSON.parse(links.match(/args: ("[^\n]+")/)[1])
    Dir.mktmpdir("macosdb-link-policy-") do |directory|
      path = Pathname.new(directory)
      %w[README.md SECURITY.md CONTRIBUTING.md docs/test.md].each do |name|
        file = path.join(name)
        file.dirname.mkpath
        file.write("fixture\n")
      end
      path.join("lychee.toml").binwrite(ROOT.join("lychee.toml").binread)
      target = nil
      %w[macos xcode].each do |product|
        target = path.join("site/dist/client", product, "release/99.0-99A1/index.html")
        target.dirname.mkpath
        target.write(%(<a href="https://macosdb.com/#{product}/release/99.0-99A1/">release</a>))
      end
      script = 'eval "set -- ${LYCHEE_ARGS}"; lychee --offline --no-progress --format json "$@"'
      env = { "GITHUB_WORKSPACE" => directory, "LYCHEE_ARGS" => args }
      result = bash(script, chdir: path, env: env)
      assert result.success?, result.stderr + result.stdout
      report = JSON.parse(result.stdout)
      assert_equal 2, report.fetch("successful")
      assert_equal 2, report.fetch("total")
      target.unlink
      path.join("site/dist/client/index.html").write('<a href="https://macosdb.com/xcode/release/99.0-99A1/index.html">missing</a>')
      refute bash(script, chdir: path, env: env).success?
    end
  end
end
