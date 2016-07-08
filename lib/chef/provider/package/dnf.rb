# Copyright:: Copyright 2016, Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef/provider/package"
require "chef/resource/dnf_package"
require "chef/mixin/which"
require "timeout"

class Chef
  class Provider
    class Package
      class Dnf < Chef::Provider::Package
        extend Chef::Mixin::Which

        Version = Struct.new(:name, :version, :arch) do
          def to_s
            "#{x.name}-#{x.version}.#{x.arch}"
          end

          def version_with_arch
            "#{x.version}.#{x.arch}" unless verison.nil?
          end
        end

        attr_accessor :python_helper

        class PythonHelper
          include Singleton
          extend Chef::Mixin::Which

          attr_accessor :stdin
          attr_accessor :stdout
          attr_accessor :stderr
          attr_accessor :wait_thr

          DNF_HELPER = ::File.expand_path(::File.join(::File.dirname(__FILE__), "dnf_helper.py")).freeze
          DNF_COMMAND = "#{which("python3")} #{DNF_HELPER}"

          def start
            ENV["PYTHONUNBUFFERED"] = "1"
            @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(DNF_COMMAND)
          end

          def reap
            Process.kill("KILL", wait_thr.pid)
            stdin.close
            stdout.close
            stderr.close
            wait_thr.value
          end

          def check
            start if stdin.nil?
          end

          # @returns Array<Version>
          def whatprovides(package_name)
            with_helper do
              stdin.syswrite "whatprovides #{package_name}\n"
              stdout.sysread(4096).split.each_slice(3).map { |x| Version.new(x) }
            end
          end

          def restart
            reap unless stdin.nil?
            start
          end

          def with_helper
            max_retries ||= 5
            Timeout.timeout(60) do
              check
              yield
            end
          rescue EOFError, Errno::EPIPE, Timeout::Error => e
            raise e unless ( max_retries -= 1 ) > 0
            restart
            retry
          end
        end

        use_multipackage_api

        provides :package, platform_family: %w{rhel fedora} do
          which("dnf")
        end

        provides :dnf_package, os: "linux"

        def python_helper
          @python_helper ||= PythonHelper.instance
        end

        def load_current_resource
          @current_resource = Chef::Resource::DnfPackage.new(new_resource.name)
          current_resource.package_name(new_resource.package_name)

          current_resource.version(get_current_versions)

          current_resource
        end

        def candidate_version
          resolve_packages if @candidate_version.nil?
          @candidate_version
        end

        # get_current_versions may not guess 'the' correct version that we later pick from
        # what is returned first for the available versions, but it will pick 'a' correct
        # version that satisfies what the user asked for -- which is good enough for an
        # idempotency check.  later if we fail the idempotency check, we will call the
        # machinery in resolve_package() and fix the current_version if we have to.
        def get_current_versions
          package_name_array.map do |pkg|
            installed_versions(pkg).first.version_with_arch
          end
        end

        def install_package(name, version)
          dnf(new_resource.options, "-y install", zip(name, version))
        end

        # dnf upgrade does not work on uninstalled packaged, while install will upgrade
        alias_method :upgrade_package, :install_package

        def remove_package(name, version)
          dnf(new_resource.options, "-y remove", zip(name, version))
        end

        alias_method :purge_package, :remove_package

        private

        # @returns Array<Version>
        def available_versions(package_name)
          python_helper.whatavailable(package_name)
        end

        # @returns Array<Version>
        def installed_versions(package_name)
          python_helper.whatinstalled(package_name)
        end

        # here is where all the magic is.  the available versions must be returned
        # by the python helper in the preferred order.  if we find an available verison
        # that matches something that is installed we pick that one.  if nothing
        # matches then we pick whatever the python script returned first.
        def resolve_package(package_name)
          available_list = available_versions(package_name)
          installed_list = installed_versions(package_name)
          # pick the first one that matches an installed version
          available = available_list.find do |a|
            installed_list.any? do |i|
              a.matches_name_and_arch?(i)
            end
          end
          # pick the first one as a default if we didn't match
          available ||= available_list.first
          # find the first matching installed version (nil if we don't match)
          installed = installed_list.find do |i|
            i.matches_name_and_arch?(available)
          end
          # normally we wouldn't update the current_resource, but in this case we
          # are actually at the point where we really know what the installed version should be
          # (we do NOT do this resolution early because we want to avoid expensively
          # resolving the candidate_version for the idempotency check)
          current_resource.version[package_name] = installed.version_with_arch if installed
          candidate_version[package_name] = available.version_with_arch if available
          real_name[package_name] = available.name if available
        end

        # loop over all the packages and resolve them to find the candidate_version, the
        # real_name (i.e. dnf_package "/usr/bin/perl" becomes "perl" because we support
        # whatprovides syntax), and then we fix up the current_resource.version that is
        # installed.
        def resolve_packages
          @candidate_version ||= {}
          @real_name ||= {}
          package_name_array.map do |pkg|
            resolve_package(pkg)
          end
        end

        def zip(names, versions)
          names.zip(versions).map do |n, v|
            (v.nil? || v.empty?) ? n : "#{@real_name[n]}-#{v}"
          end
        end

        def dnf(*args)
          shell_out_with_timeout!(a_to_s("dnf", *args))
        end

      end
    end
  end
end
