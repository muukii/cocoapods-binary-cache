module PodPrebuild
  class PreInstallHook
    include ObjectSpace

    attr_reader :installer_context, :podfile, :prebuild_sandbox, :cache_validation

    def initialize(installer_context)
      @installer_context = installer_context
      @podfile = installer_context.podfile
      @pod_install_options = {}
      @prebuild_sandbox = nil
      @cache_validation = nil
    end

    def run
      require_relative "../pod-binary/helper/feature_switches"
      return if Pod.is_prebuild_stage

      log_section "🚀  Prebuild frameworks"
      ensure_valid_podfile
      save_installation_states
      prepare_environment
      create_prebuild_sandbox
      Pod::UI.section("Detect implicit dependencies") { detect_implicit_dependencies }
      Pod::UI.section("Validate prebuilt cache") { validate_cache }
      install!
      reset_environment
      log_section "🤖  Resume pod installation"
      require_relative "../pod-binary/integration"
    end

    private

    def save_installation_states
      save_pod_install_options
      save_states_from_dsl
    end

    def save_pod_install_options
      # Fetch original installer (which is running this pre-install hook) options,
      # then pass them to our installer to perform update if needed
      # Looks like this is the most appropriate way to figure out that something should be updated
      @original_installer = ObjectSpace.each_object(Pod::Installer).first
      @pod_install_options[:update] = @original_installer.update
      @pod_install_options[:repo_update] = @original_installer.repo_update
    end

    def ensure_valid_podfile
      podfile.target_definition_list.each do |target_definition|
        next if target_definition.prebuild_framework_pod_names.empty?

        unless target_definition.uses_frameworks?
          warn "[!] Cocoapods-binary requires `use_frameworks!`".red
          exit
        end
      end
    end

    def prepare_environment
      Pod::UI.puts "Prepare environment"
      Pod.is_prebuild_stage = true
      Pod::Podfile::DSL.enable_prebuild_patch true  # enable sikpping for prebuild targets
      Pod::Installer.force_disable_integration true # don't integrate targets
      Pod::Config.force_disable_write_lockfile true # disbale write lock file for perbuild podfile
      Pod::Installer.disable_install_complete_message true # disable install complete message
    end

    def reset_environment
      Pod::UI.puts "Reset environment"
      Pod.is_prebuild_stage = false
      Pod::Installer.force_disable_integration false
      Pod::Podfile::DSL.enable_prebuild_patch false
      Pod::Config.force_disable_write_lockfile false
      Pod::Installer.disable_install_complete_message false
      Pod::UserInterface.warnings = [] # clean the warning in the prebuild step, it's duplicated.
    end

    def save_states_from_dsl
      # Note: DSL is reloaded when creating an installer (Pod::Installer.new).
      # Any mutation to DSL is highly discouraged
      # --> Rather, perform mutation on PodPrebuild::StateStore instead
      PodPrebuild::StateStore.excluded_pods += Pod::Podfile::DSL.excluded_pods
    end

    def create_prebuild_sandbox
      standard_sandbox = installer_context.sandbox
      @prebuild_sandbox = Pod::PrebuildSandbox.from_standard_sandbox(standard_sandbox)
      Pod::UI.puts "Create prebuild sandbox at #{@prebuild_sandbox.root}"
    end

    def detect_implicit_dependencies
      @original_installer.resolve_dependencies
      specs = @original_installer.analysis_result.specifications

      pods_with_empty_source_files = specs
        .select(&:empty_source_files?)
        .flat_map { |spec| [spec.name, spec.name.split("/")[0]] }
        .to_set
      PodPrebuild::StateStore.excluded_pods += pods_with_empty_source_files
      Pod::UI.puts "Exclude pods with empty source files: #{pods_with_empty_source_files.to_a}"

      # TODO (thuyen): Detect dependencies of a prebuilt pod and treat them as prebuilt pods as well
    end

    def validate_cache
      prebuilt_lockfile = Pod::Lockfile.from_file(prebuild_sandbox.root + "Manifest.lock")
      @cache_validation = PodPrebuild::CacheValidator.new(
        podfile: Pod::Podfile.from_ruby(podfile.defined_in_file),
        pod_lockfile: installer_context.lockfile,
        prebuilt_lockfile: prebuilt_lockfile,
        validate_prebuilt_settings: Pod::Podfile::DSL.validate_prebuilt_settings,
        generated_framework_path: prebuild_sandbox.generate_framework_path,
        sandbox_root: prebuild_sandbox.root,
        ignored_pods: PodPrebuild::StateStore.excluded_pods
      ).validate
      cache_validation.print_summary
      PodPrebuild::StateStore.cache_validation = cache_validation
    end

    def install!
      binary_installer = Pod::PrebuildInstaller.new(
        sandbox: prebuild_sandbox,
        podfile: Pod::Podfile.from_ruby(podfile.defined_in_file),
        lockfile: installer_context.lockfile,
        cache_validation: cache_validation
      )

      binary_installer.clean_delta_file

      installer_exec = lambda do
        binary_installer.update = @pod_install_options[:update]
        binary_installer.repo_update = @pod_install_options[:repo_update]
        binary_installer.install!
      end

      if Pod::Podfile::DSL.prebuild_all_vendor_pods
        Pod::UI.puts "Prebuild all vendor pods"
        installer_exec.call
      elsif !@pod_install_options[:update] && cache_validation.missed.empty?
        # If not in prebuild job, we never rebuild and just use cache
        Pod::UI.puts "Cache hit"
        binary_installer.install_when_cache_hit!
      else
        Pod::UI.puts "Cache miss -> need to update: #{cache_validation.missed.to_a}"
        installer_exec.call
      end
    end

    def log_section(message)
      Pod::UI.puts "-----------------------------------------"
      Pod::UI.puts message
      Pod::UI.puts "-----------------------------------------"
    end
  end
end