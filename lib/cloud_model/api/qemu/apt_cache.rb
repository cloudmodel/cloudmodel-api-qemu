require 'rbconfig'
require 'fileutils'
require 'socket'

module CloudModel
  module Api
    module Qemu
      # Lifecycle of the workstation-side apt cache proxy (see
      # apt_cache_daemon.rb). Started on demand when a VM starts; VMs reach
      # it as http://10.0.2.2:<port> through QEMU's user-mode NAT.
      class AptCache
        # Address of the workstation as seen from inside the VMs
        GUEST_GATEWAY = '10.0.2.2'

        class << self
          def config
            CloudModel.config.api.qemu
          end

          def proxy_url
            "http://#{GUEST_GATEWAY}:#{config.apt_cache_port}"
          end

          def cache_dir
            File.join(config.vm_dir, 'apt-cache')
          end

          def pid_path
            File.join(cache_dir, 'daemon.pid')
          end

          def log_path
            File.join(cache_dir, 'daemon.log')
          end

          def running?
            return false unless File.exist?(pid_path)
            pid = File.read(pid_path).strip.to_i
            Process.kill(0, pid)
            true
          rescue Errno::ESRCH, Errno::EPERM
            false
          end

          # Best effort — a missing cache must never block VM operations;
          # the VMs' apt config is only written when this succeeded once.
          def ensure_running!
            return false unless config.apt_cache
            return true if running?

            FileUtils.mkdir_p cache_dir
            daemon = File.expand_path('apt_cache_daemon.rb', __dir__)
            pid = Process.spawn(
              RbConfig.ruby, daemon, config.apt_cache_port.to_s, cache_dir,
              in: '/dev/null', out: log_path, err: log_path, pgroup: true
            )
            Process.detach pid
            File.write pid_path, pid.to_s

            # The proxy must accept connections before a VM boots with it
            # configured — give WEBrick a moment.
            20.times do
              break if listening?
              sleep 0.25
            end

            listening?.tap do |ok|
              puts "[cloudmodel-api-qemu] apt cache proxy #{ok ? "up at #{proxy_url}" : "FAILED to start (see #{log_path})"}"
            end
          end

          def stop
            return false unless File.exist?(pid_path)
            pid = File.read(pid_path).strip.to_i
            Process.kill 'TERM', pid
            FileUtils.rm_f pid_path
            true
          rescue Errno::ESRCH
            FileUtils.rm_f pid_path
            false
          end

          def listening?
            TCPSocket.new('127.0.0.1', config.apt_cache_port).close
            true
          rescue SystemCallError
            false
          end

          def status
            {
              enabled: config.apt_cache,
              running: running?,
              url: proxy_url,
              cache_dir: cache_dir,
              cached_files: Dir.glob(File.join(cache_dir, '**', '*')).count { |f| File.file?(f) && !f.end_with?('.pid', '.log') }
            }
          end
        end
      end
    end
  end
end
