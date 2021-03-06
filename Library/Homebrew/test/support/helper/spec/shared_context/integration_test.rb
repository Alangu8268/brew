require "rspec"
require "open3"

RSpec::Matchers.define_negated_matcher :not_to_output, :output
RSpec::Matchers.define_negated_matcher :be_a_failure, :be_a_success

RSpec.shared_context "integration test" do
  extend RSpec::Matchers::DSL

  matcher :be_a_success do
    match do |actual|
      status = actual.is_a?(Proc) ? actual.call : actual
      status.respond_to?(:success?) && status.success?
    end

    def supports_block_expectations?
      true
    end

    # It needs to be nested like this:
    #
    #   expect {
    #     expect {
    #       # command
    #     }.to be_a_success
    #   }.to output(something).to_stdout
    #
    # rather than this:
    #
    #   expect {
    #     expect {
    #       # command
    #     }.to output(something).to_stdout
    #   }.to be_a_success
    #
    def expects_call_stack_jump?
      true
    end
  end

  before(:each) do
    (HOMEBREW_PREFIX/"bin").mkpath
    FileUtils.touch HOMEBREW_PREFIX/"bin/brew"
  end

  after(:each) do
    FileUtils.rm HOMEBREW_PREFIX/"bin/brew"
    FileUtils.rmdir HOMEBREW_PREFIX/"bin"
  end

  # Generate unique ID to be able to
  # properly merge coverage results.
  def command_id_from_args(args)
    @command_count ||= 0
    pretty_args = args.join(" ").gsub(TEST_TMPDIR, "@TMPDIR@")
    file_and_line = caller[1].sub(/(.*\d+):.*/, '\1')
                             .sub("#{HOMEBREW_LIBRARY_PATH}/test/", "")
    "#{file_and_line}:brew #{pretty_args}:#{@command_count += 1}"
  end

  # Runs a `brew` command with the test configuration
  # and with coverage reporting enabled.
  def brew(*args)
    env = args.last.is_a?(Hash) ? args.pop : {}

    env.merge!(
      "HOMEBREW_BREW_FILE" => HOMEBREW_PREFIX/"bin/brew",
      "HOMEBREW_INTEGRATION_TEST" => command_id_from_args(args),
      "HOMEBREW_TEST_TMPDIR" => TEST_TMPDIR,
      "HOMEBREW_DEVELOPER" => ENV["HOMEBREW_DEVELOPER"],
    )

    ruby_args = [
      "-W0",
      "-I", "#{HOMEBREW_LIBRARY_PATH}/test/support/lib",
      "-I", HOMEBREW_LIBRARY_PATH.to_s,
      "-rconfig"
    ]
    ruby_args << "-rsimplecov" if ENV["HOMEBREW_TESTS_COVERAGE"]
    ruby_args << "-rtest/support/helper/integration_mocks"
    ruby_args << (HOMEBREW_LIBRARY_PATH/"brew.rb").resolved_path.to_s

    Bundler.with_original_env do
      stdout, stderr, status = Open3.capture3(env, RUBY_PATH, *ruby_args, *args)
      $stdout.print stdout
      $stderr.print stderr
      status
    end
  end

  def setup_test_formula(name, content = nil)
    case name
    when /^testball/
      content = <<-EOS.undent
        desc "Some test"
        homepage "https://example.com/#{name}"
        url "file://#{TEST_FIXTURE_DIR}/tarballs/testball-0.1.tbz"
        sha256 "#{TESTBALL_SHA256}"

        option "with-foo", "Build with foo"

        def install
          (prefix/"foo"/"test").write("test") if build.with? "foo"
          prefix.install Dir["*"]
          (buildpath/"test.c").write \
            "#include <stdio.h>\\nint main(){return printf(\\"test\\");}"
          bin.mkpath
          system ENV.cc, "test.c", "-o", bin/"test"
        end

        #{content}

        # something here
      EOS
    when "foo"
      content = <<-EOS.undent
        url "https://example.com/#{name}-1.0"
      EOS
    when "bar"
      content = <<-EOS.undent
        url "https://example.com/#{name}-1.0"
        depends_on "foo"
      EOS
    end

    Formulary.core_path(name).tap do |formula_path|
      formula_path.write <<-EOS.undent
        class #{Formulary.class_s(name)} < Formula
          #{content}
        end
      EOS
    end
  end

  def setup_remote_tap(name)
    Tap.fetch(name).tap do |tap|
      tap.install(full_clone: false, quiet: true) unless tap.installed?
    end
  end

  def install_and_rename_coretap_formula(old_name, new_name)
    shutup do
      CoreTap.instance.path.cd do |tap_path|
        system "git", "init"
        system "git", "add", "--all"
        system "git", "commit", "-m",
          "#{old_name.capitalize} has not yet been renamed"

        brew "install", old_name

        (tap_path/"Formula/#{old_name}.rb").unlink
        (tap_path/"formula_renames.json").write JSON.generate(old_name => new_name)

        system "git", "add", "--all"
        system "git", "commit", "-m",
          "#{old_name.capitalize} has been renamed to #{new_name.capitalize}"
      end
    end
  end

  def testball
    "#{TEST_FIXTURE_DIR}/testball.rb"
  end
end

RSpec.configure do |config|
  config.include_context "integration test", :integration_test
end
