require_relative "../source_installer"

module Pod
  class Installer
    # Override the download step to skip download and prepare file in target folder
    alias original_create_pod_installer create_pod_installer
    def create_pod_installer(name)
      if should_integrate_prebuilt_pod?(name)
        create_prebuilt_source_installer(name)
      else
        create_normal_source_installer(name)
      end
    end

    private

    def create_normal_source_installer(name)
      original_create_pod_installer(name)
    end

    def create_prebuilt_source_installer(name)
      source_installer = PodSourceInstaller.new(sandbox, podfile, specs_for_pod(name))
      pod_installer = PrebuiltSourceInstaller.new(
        sandbox,
        podfile,
        specs_for_pod(name),
        source_installer: source_installer
      )
      pod_installers << pod_installer
      pod_installer
    end

    def should_integrate_prebuilt_pod?(name)
      if PodPrebuild.config.prebuild_job? && PodPrebuild.config.targets_to_prebuild_from_cli.empty?
        # In a prebuild job, at the integration stage, all prebuilt frameworks should be
        # ready for integration regardless of whether there was any cache miss or not.
        # Those that are missed were prebuilt in the prebuild stage.
        PodPrebuild.state.cache_validation.include?(name)
      else
        prebuilt = PodPrebuild.state.cache_validation.hit + PodPrebuild.config.targets_to_prebuild_from_cli
        prebuilt.include?(name)
      end
    end
  end
end
