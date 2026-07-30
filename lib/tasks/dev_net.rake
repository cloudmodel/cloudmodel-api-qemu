require 'json'
require 'rbconfig'
require 'cloud_model/api/qemu/dev_net'

# dev:net — host-side routing + split-horizon DNS for the local QEMU dev cloud.
# Replaces the old `dev:vm:mac_network` / `dev:vm:mac_hosts` scripts and the
# hosts.erb split-horizon detour. Session-scoped, idempotent, no permanent
# daemon. See lib/cloud_model/api/qemu/dev_net/*.
namespace :dev do
  namespace :net do
    def dev_net_paths
      vm_dir = CloudModel.config.api.qemu.vm_dir
      {
        exec:    CloudModel::Api::Qemu::DevNet.libexec('cm-dev-net-exec'),
        dns:     CloudModel::Api::Qemu::DevNet.libexec('cm-dev-net-dns'),
        plan:    File.join(vm_dir, 'dev-net-plan.json'),
        pidfile: File.join(vm_dir, 'dev-net-dns.pid'),
        logfile: File.join(vm_dir, 'dev-net-dns.log')
      }
    end

    # Run the current Ruby (rbenv/rvm-correct) under sudo — a plain `sudo ruby`
    # could pick a different, too-old interpreter.
    def sudo_exec(action, plan_path, exec_path)
      verb = action == 'up' ? 'add' : 'remove'
      puts ''
      puts "── Administrator rights required ─────────────────────────────────────"
      puts "To #{verb} the network routes and the /etc/resolver entry, the next step"
      puts "runs a local helper as root. macOS/sudo will now prompt for YOUR login"
      puts "password (input is hidden). Nothing is sent anywhere — it only runs:"
      puts "  #{exec_path} #{action}"
      puts "──────────────────────────────────────────────────────────────────────"
      cmd = ['sudo', RbConfig.ruby, exec_path, action, plan_path]
      system(*cmd)
    end

    def forwarder_running?(pidfile)
      return false unless File.exist?(pidfile)
      pid = File.read(pidfile).to_i
      pid > 0 && (Process.kill(0, pid) rescue false) && true
    end

    def start_forwarder(plan, paths)
      # Always (re)start: a forwarder left over from a previous `up` carries that
      # run's override set (e.g. old zone names), so reusing it would silently
      # serve stale answers. Stop it and spawn a fresh one for the current plan.
      if forwarder_running?(paths[:pidfile])
        puts 'Restarting DNS forwarder to load the current names…'
        stop_forwarder(paths, quiet: true)
        20.times { break unless forwarder_running?(paths[:pidfile]); sleep 0.1 }
      end
      dns  = plan['dns']
      args = [RbConfig.ruby, paths[:dns], '--listen', dns['listen'], '--port', dns['port'].to_s,
              '--pidfile', paths[:pidfile], '--logfile', paths[:logfile]]
      dns['upstreams'].each     { |u| args.push('--upstream', u) }
      dns['overrides'].each     { |name, ip| args.push('--override', "#{name}=#{ip}") }
      (dns['zones'] || []).each { |z| args.push('--zone', z) }
      (dns['live_cidrs'] || []).each { |c| args.push('--live-cidr', c) }
      if (mongo = dns['mongo'])
        Array(mongo['hosts']).each { |h| args.push('--mongo-host', h) }
        args.push('--mongo-db', mongo['database']) if mongo['database']
        args.push('--mongo-collection', mongo['collection']) if mongo['collection']
      end

      # Spawn inheriting the current (bundler) env so the forwarder can `require
      # 'mongo'` for live DB resolution; falls back to static + forward if absent.
      pid = Process.spawn(*args, out: paths[:logfile], err: paths[:logfile], pgroup: true)
      Process.detach(pid)
      live = dns['mongo'] && !Array(dns['mongo']['hosts']).empty? ? 'live DB + ' : ''
      puts "DNS forwarder started (pid #{pid}) on #{dns['listen']}:#{dns['port']} " \
           "— #{dns['overrides'].size} static name(s), #{live}forwarding to #{dns['upstreams'].join(', ')}."
    end

    def stop_forwarder(paths, quiet: false)
      unless forwarder_running?(paths[:pidfile])
        puts 'DNS forwarder not running.' unless quiet
        File.delete(paths[:pidfile]) if File.exist?(paths[:pidfile])
        return
      end
      pid = File.read(paths[:pidfile]).to_i
      Process.kill('TERM', pid)
      puts "DNS forwarder stopped (pid #{pid})." unless quiet
    end

    def print_plan(plan)
      puts "platform     : #{plan['platform']}"
      puts "allowed nets : #{plan['allowed_cidrs'].join(', ')}"
      puts "scope domains: #{plan['scope_domains'].join(', ')}"
      puts "\nrouting + resolver operations:"
      plan['ops'].each { |op| puts "  #{op['op'].ljust(13)} #{op.reject { |k, _| k == 'op' }.map { |k, v| "#{k}=#{v}" }.join(' ')}" }
      dns = plan['dns']
      puts "\nDNS forwarder: #{dns['listen']}:#{dns['port']} → upstreams #{dns['upstreams'].join(', ')}"
      puts "  static overrides (#{dns['overrides'].size}):"
      dns['overrides'].each { |name, ip| puts "    #{name.ljust(32)} #{ip.ljust(15)} [config]" }
      zones = dns['zones'] || []
      mongo = dns['mongo']
      if mongo && !Array(mongo['hosts']).empty?
        puts "  live DB (#{mongo['hosts'].join(',')}/#{mongo['database']}): any other *.{#{zones.join(',')}} " \
             "name resolved on demand from #{mongo['collection']}"
      else
        puts '  live DB: unavailable (static overrides + upstream forwarding only)'
      end
    end

    def print_status(plan, paths)
      status = CloudModel::Api::Qemu::DevNet::Status.new(plan: plan, pidfile: paths[:pidfile])
      puts "\nstatus:"
      status.checks.each { |c| puts "  #{c.ok ? '✓' : '✗'} #{c.name.ljust(34)} #{c.detail}" }
      puts status.ok? ? "\nAll green." : "\nSome checks failed (see above)."
    end

    def build_plan
      CloudModel::Api::Qemu::DevNet::Planner.build.first
    rescue CloudModel::Api::Qemu::DevNet::Error => e
      abort "dev:net: #{e.message}"
    end

    desc 'Show the routing + DNS plan without changing anything (dry run)'
    task plan: :environment do
      print_plan(build_plan)
    end

    desc 'Bring up dev-cloud routing + split-horizon DNS (needs sudo once)'
    task up: :environment do
      paths = dev_net_paths
      plan  = build_plan
      File.open(paths[:plan], 'w', 0o600) { |f| f.write(JSON.pretty_generate(plan)) }

      start_forwarder(plan, paths)
      unless sudo_exec('up', paths[:plan], paths[:exec])
        stop_forwarder(paths)
        abort 'dev:net:up: privileged step failed — rolled back the forwarder.'
      end
      print_status(plan, paths)
    end

    desc 'Tear down dev-cloud routing + DNS, removing everything'
    task down: :environment do
      paths = dev_net_paths
      # Prefer the plan that was actually applied; fall back to a fresh build.
      plan = File.exist?(paths[:plan]) ? JSON.parse(File.read(paths[:plan])) : build_plan

      sudo_exec('down', write_transient_plan(plan, paths), paths[:exec])
      stop_forwarder(paths)
      File.delete(paths[:plan]) if File.exist?(paths[:plan])
      print_status(plan, paths)
    end

    desc 'Verify the live system: routes present + names resolve to dev IPs'
    task status: :environment do
      paths = dev_net_paths
      plan  = File.exist?(paths[:plan]) ? JSON.parse(File.read(paths[:plan])) : build_plan
      print_status(plan, paths)
    end

    # `down` may run from a freshly-built plan (no applied file). Persist it so
    # the executor reads from a stable 0600 path.
    def write_transient_plan(plan, paths)
      return paths[:plan] if File.exist?(paths[:plan])
      tmp = File.join(CloudModel.config.api.qemu.vm_dir, 'dev-net-plan.down.json')
      File.open(tmp, 'w', 0o600) { |f| f.write(JSON.pretty_generate(plan)) }
      tmp
    end

    # ── Local CA for the dev zones ──────────────────────────────────────────────
    def dev_zones
      build_plan['scope_domains']
    end

    def ca
      CloudModel::Api::Qemu::DevNet::Ca.new(dir: File.join(CloudModel.config.api.qemu.vm_dir, 'dev-net-ca'))
    end

    namespace :ca do
      desc 'Create/refresh the local CA + a leaf cert covering the dev zones (no sudo)'
      task create: :environment do
        zones = dev_zones
        result = ca.ensure!(zones)
        puts "dev zones : #{result[:zones].join(', ')}"
        puts "CA cert   : #{result[:ca_cert]}#{result[:created_ca] ? '  (created)' : ''}"
        puts "leaf cert : #{result[:leaf_cert]}#{result[:regenerated_leaf] ? '  (regenerated)' : ''}"
        puts "leaf key  : #{result[:leaf_key]}"
        puts "\nSANs cover #{result[:zones].map { |z| "#{z}, *.#{z}" }.join(', ')}."
        puts 'Next: `rake dev:net:ca:trust` (sudo) to trust the CA on this Mac, and'
        puts 'install the leaf cert on the dev guests (nginx) + the CA where clients need it.'
      end

      desc 'Trust the local CA on this workstation (sudo once)'
      task trust: :environment do
        paths = dev_net_paths
        ca.ensure!(dev_zones)
        unless sudo_exec_ca('trust-ca', ca.ca_cert_path, paths[:exec])
          abort 'dev:net:ca:trust: failed to trust the CA.'
        end
      end

      desc 'Remove the local CA from this workstation trust store (sudo once)'
      task untrust: :environment do
        paths = dev_net_paths
        abort "no CA at #{ca.ca_cert_path}" unless File.exist?(ca.ca_cert_path)
        sudo_exec_ca('untrust-ca', ca.ca_cert_path, paths[:exec])
      end
    end

    def sudo_exec_ca(action, cert_path, exec_path)
      verb = action == 'trust-ca' ? 'trust' : 'untrust'
      puts ''
      puts "── Administrator rights required ─────────────────────────────────────"
      puts "To #{verb} the local dev CA in the system keychain, the next step runs a"
      puts "local helper as root. sudo will prompt for YOUR login password. It runs:"
      puts "  #{exec_path} #{action} #{cert_path}"
      puts "──────────────────────────────────────────────────────────────────────"
      system('sudo', RbConfig.ruby, exec_path, action, cert_path)
    end
  end
end
