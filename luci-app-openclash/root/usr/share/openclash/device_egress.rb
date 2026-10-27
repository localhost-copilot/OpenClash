#!/usr/bin/ruby
# Run after all other overwrites, so custom listeners/ports are checked too.
require 'yaml'
require 'json'
require 'tempfile'

module DeviceEgress
  PREFIX = 'openclash-device-'.freeze
  DIRECT = %w[DIRECT COMPATIBLE].freeze
  HARDENING = 'x-openclash-device-egress'.freeze

  def self.load_yaml(path)
    value = YAML.safe_load(File.read(path), permitted_classes: [], aliases: true)
    raise 'Invalid YAML configuration' unless value.is_a?(Hash)
    value
  end

  def self.catalogue(config, root, live = {})
    nodes = {}
    Array(config['proxies']).each { |node| nodes[node.fetch('name')] = node }
    configured_nodes = nodes.dup
    groups = {}
    Array(config['proxy-groups']).each { |group| groups[group.fetch('name')] = group }
    providers = {}
    (config['proxy-providers'] || {}).each do |name, provider|
      begin
        if provider['type'] == 'inline'
          providers[name] = Array(provider.fetch('payload'))
        else
          path = File.expand_path(provider.fetch('path'), root)
          raise 'Provider is outside OpenClash' unless path.start_with?(File.expand_path(root) + '/')
          # OpenClash normalizes provider paths during its final YAML pass.
          path = File.join(root, 'proxy_provider', File.basename(path)) unless File.file?(path)
          providers[name] = Array(load_yaml(path).fetch('proxies'))
        end
      rescue StandardError
        # An unexpanded provider cannot be proven free of DIRECT.
        providers[name] = nil
      end
    end
    providers.values.compact.flatten.each { |node| nodes[node.fetch('name')] ||= node }
    # Runtime provider names include name overrides; the provider API supplies
    # their actual adapter types, so a renamed DIRECT cannot hide behind a name.
    (live['providers'] || {}).each do |name, provider|
      next unless providers.key?(name)
      members = Array(provider['proxies'])
      providers[name] += members if providers[name]
      members.each { |node| nodes[node.fetch('name')] = node }
    end
    unsafe_node = lambda do |node|
      DIRECT.include?(node['name']) || %w[direct compatible].include?(node['type'].to_s.downcase)
    end
    unsafe_name = nil
    unsafe_name = lambda do |name, visiting|
      return true if DIRECT.include?(name)
      return false if name == 'REJECT' || name == 'REJECT-DROP'
      return true if visiting.include?(name)
      group = groups[name]
      return nodes[name] ? unsafe_node.call(nodes[name]) : true unless group
      path = visiting + [name]
      members = Array(group['proxies']).dup
      members += configured_nodes.keys if group['include-all'] || group['include-all-proxies']
      uses = Array(group['use']).dup
      uses += providers.keys if group['include-all'] || group['include-all-providers']
      # Checking a superset deliberately ignores filters: filters must never
      # hide a DIRECT path, and Go and Ruby regex semantics can differ.
      return true if uses.uniq.any? { |provider| providers[provider].nil? || providers[provider].any? { |node| unsafe_node.call(node) } }
      runtime = live.fetch('proxies', {})[name]
      members += Array(runtime['all']) if runtime.is_a?(Hash)
      empty = members.empty? && uses.all? { |provider| providers[provider].empty? }
      members << (group['empty-fallback'] || 'COMPATIBLE') if empty
      members.any? { |member| unsafe_name.call(member, path) }
    end
    entries = groups.values.map do |group|
      runtime = live.fetch('proxies', {})[group['name']] || {}
      { 'name' => group['name'], 'kind' => 'group', 'type' => group['type'],
        'unsafe' => unsafe_name.call(group['name'], []), 'current' => runtime['now'] }
    end
    entries + configured_nodes.values.map do |node|
      { 'name' => node['name'], 'kind' => 'node', 'type' => node['type'], 'unsafe' => !!unsafe_node.call(node) }
    end
  end

  def self.restore_groups(config)
    originals = config.delete(HARDENING) || {}
    Array(config['proxy-groups']).each do |group|
      (originals[group['name']] || {}).each do |key, original|
        original['present'] ? group[key] = original['value'] : group.delete(key)
      end
    end
  end

  def self.harden_groups(config, targets)
    groups = Array(config['proxy-groups']).each_with_object({}) { |group, all| all[group['name']] = group }
    originals = {}
    visit = nil
    visit = lambda do |name|
      group = groups[name]
      return unless group && !originals.key?(name)
      originals[name] = {}
      %w[empty-fallback exclude-type].each do |key|
        originals[name][key] = { 'present' => group.key?(key), 'value' => group[key] }
      end
      # A provider may become empty or add a direct adapter after loading. The
      # selected graph must never acquire Mihomo's default COMPATIBLE fallback.
      group['empty-fallback'] = 'REJECT'
      group['exclude-type'] = (group.fetch('exclude-type', '').split('|') + %w[Direct Compatible]).uniq.join('|').sub(/^\|/, '')
      Array(group['proxies']).each { |child| visit.call(child) }
    end
    targets.each { |target| visit.call(target) }
    config[HARDENING] = originals unless originals.empty?
  end

  def self.listeners(config, rows, root)
    had_hardening = config.key?(HARDENING)
    restore_groups(config)
    existing = Array(config['listeners'])
    owned = existing.select { |item| item['name'].to_s.start_with?(PREFIX) }
    return false if rows.empty? && owned.empty? && !had_hardening
    existing = existing - owned
    used = []
    %w[port socks-port redir-port tproxy-port mixed-port external-controller external-controller-tls external-controller-doh].each do |key|
      value = config[key]
      used << value.to_s.split(':').last.to_i if value
    end
    used << config.dig('dns', 'listen').to_s.split(':').last.to_i
    existing.each do |item|
      item.fetch('port', '').to_s.split(',').each do |range|
        first, last = range.split('-').map(&:to_i)
        used.concat((first..(last || first)).to_a)
      end
    end
    entries = catalogue(config, root).each_with_object({}) { |item, all| all[item['name']] = item }
    selected_groups = []
    rows.each_with_index do |row, index|
      next unless row['enabled'] == '1'
      port = 7901 + index
      raise "Device listener port #{port} is already in use" if used.include?(port)
      # A newly missing/unsafe target stays guarded, with no listening socket.
      target = entries[row['target']]
      next unless target && !target['unsafe']
      selected_groups << row['target']
      existing << { 'name' => PREFIX + row.fetch('mac').delete(':').downcase,
                    'type' => 'tproxy', 'listen' => '0.0.0.0', 'port' => port,
                    'udp' => true, 'proxy' => row.fetch('target') }
    end
    harden_groups(config, selected_groups)
    config['listeners'] = existing
    true
  end

  def self.write_atomic(path, value)
    file = Tempfile.new(['.device-egress-', '.yaml'], File.dirname(path))
    begin
      file.write(YAML.dump(value))
      file.flush
      file.fsync
      File.chmod(File.stat(path).mode & 0o777, file.path)
      File.rename(file.path, path)
    ensure
      file.close!
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command, path, root = ARGV
    root ||= '/etc/openclash'
    config = DeviceEgress.load_yaml(path)
    input = JSON.parse(STDIN.read)
    case command
    when 'catalogue'
      # luci.jsonc encodes an empty Lua table as [], including the offline
      # catalogue's empty API snapshot. Treat it as an empty object here.
      puts JSON.generate(DeviceEgress.catalogue(config, root, input.is_a?(Hash) ? input : {}))
    when 'generate'
      DeviceEgress.write_atomic(path, config) if DeviceEgress.listeners(config, input, root)
    when 'inspect'
      puts JSON.generate(Array(config['listeners']).select { |item| item['name'].to_s.start_with?(DeviceEgress::PREFIX) })
    else
      raise 'Unknown device egress operation'
    end
  rescue StandardError => e
    warn e.message
    exit 1
  end
end
