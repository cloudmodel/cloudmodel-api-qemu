# frozen_string_literal: true

require 'ipaddr'
require 'socket'
require 'shellwords'

module CloudModel
  module Api
    module Qemu
      module DevNet
        # Reality verification for `dev:net:status` — it does not trust that
        # `up` "should have" worked; it probes the live system and confirms the
        # routes are actually present and the names actually resolve to the dev
        # IPs. All read-only, so it needs no privileges.
        class Status
          Check = Struct.new(:name, :ok, :detail, keyword_init: true)

          def initialize(plan:, pidfile:, platform: nil)
            @plan     = plan
            @pidfile  = pidfile
            @platform = platform || plan['platform']
          end

          def checks
            [forwarder_check] + route_checks + resolver_checks + resolution_checks
          end

          def ok? = checks.all?(&:ok)

          private

          def forwarder_check
            pid = File.read(@pidfile).to_i if File.exist?(@pidfile)
            alive = pid && pid > 0 && (Process.kill(0, pid) rescue false) && true
            Check.new(name: 'dns forwarder', ok: !!alive,
                      detail: alive ? "running (pid #{pid})" : 'not running')
          end

          def route_ops = @plan['ops'].select { |o| %w[route_add ip_route_add].include?(o['op']) }

          def route_checks
            route_ops.map do |op|
              probe = probe_ip(op['net'])
              gw = route_gateway(probe)
              ok = gw == op['via']
              Check.new(name: "route #{op['net']}", ok: ok,
                        detail: ok ? "via #{op['via']}" : "expected via #{op['via']}, got #{gw || '(none)'}")
            end
          end

          def resolver_checks
            @plan['ops'].select { |o| %w[resolver_file resolvectl].include?(o['op']) }.map do |op|
              if @platform == 'darwin'
                path = File.join('/etc/resolver', op['domain'])
                Check.new(name: "resolver #{op['domain']}", ok: File.exist?(path),
                          detail: File.exist?(path) ? path : "missing #{path}")
              else
                present = `resolvectl domain 2>/dev/null`.include?("~#{op['domain']}")
                Check.new(name: "resolver #{op['domain']}", ok: present,
                          detail: present ? "scoped to #{op['link']}" : 'domain not scoped')
              end
            end
          end

          # Actually resolve a couple of override names through the SYSTEM resolver
          # (so this exercises the resolver scoping + the forwarder end to end) and
          # confirm they land on the configured dev IP.
          def resolution_checks
            overrides = @plan.dig('dns', 'overrides') || {}
            overrides.first(3).map do |name, expected|
              got = resolve(name)
              ok = got == expected
              Check.new(name: "resolve #{name}", ok: ok,
                        detail: ok ? "-> #{expected}" : "expected #{expected}, got #{got || '(no answer)'}")
            end
          end

          # ── platform probes ──────────────────────────────────────────────────
          def probe_ip(cidr)
            net = IPAddr.new(cidr)
            (net.to_range.first.to_i + 1).then { |i| IPAddr.new(i, Socket::AF_INET).to_s }
          rescue StandardError
            cidr.split('/').first
          end

          def route_gateway(ip)
            if @platform == 'darwin'
              out = `route -n get #{ip.shellescape} 2>/dev/null`
              out[/gateway:\s*([0-9.]+)/, 1]
            else
              out = `ip route get #{ip.shellescape} 2>/dev/null`
              out[/\bvia\s+([0-9.]+)/, 1]
            end
          rescue StandardError
            nil
          end

          def resolve(name)
            if @platform == 'darwin'
              out = `dscacheutil -q host -a name #{name.shellescape} 2>/dev/null`
              out[/ip_address:\s*([0-9.]+)/, 1]
            else
              out = `resolvectl query #{name.shellescape} 2>/dev/null`
              out[/#{Regexp.escape(name)}:\s*([0-9.]+)/, 1]
            end
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
