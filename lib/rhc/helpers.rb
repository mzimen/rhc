require 'commander/user_interaction'
require 'rhc/version'
require 'rhc/config'
require 'rhc/commands'
require 'rhc/output_helpers'

require 'resolv'

OptionParser.accept(URI) {|s,| URI.parse(s) if s}

module RHC

  module Helpers
    private
      def self.global_option(*args, &block)
        RHC::Commands.global_option *args, &block
      end
  end

  module Helpers

    # helpers always have Commander UI available
    include Commander::UI
    include Commander::UI::AskForClass
    include RHC::OutputHelpers

    extend self

    MAX_RETRIES = 7
    DEFAULT_DELAY_THROTTLE = 2.0

    def disable_deprecated?
      # 1) default for now is false
      # 2) when releasing a 1.0 beta flip this to true
      # 3) all deprecated aliases should be removed right before 1.0
      disable = false

      env_disable = ENV['DISABLE_DEPRECATED']
      disable = true if env_disable == '1'

      disable
    end

    def decode_json(s)
      RHC::Vendor::OkJson.decode(s)
    end

    def date(s)
      now = Time.now
      d = datetime_rfc3339(s)
      if now.year == d.year
        return d.strftime('%l:%M %p').strip if now.yday == d.yday
      end
      d.strftime('%b %d %l:%M %p')
    rescue ArgumentError
      "Unknown date"
    end

    def datetime_rfc3339(s)
      DateTime.strptime(s, '%Y-%m-%dT%H:%M:%S%z')
      # Replace with d = DateTime.rfc3339(s)
    end

    #
    # Web related requests
    #

    def user_agent
      "rhc/#{RHC::VERSION::STRING} (ruby #{RUBY_VERSION}; #{RUBY_PLATFORM})#{" (API #{RHC::Rest::API_VERSION})" rescue ''}"
    end

    def get(uri, opts=nil, *args)
      opts = {'User-Agent' => user_agent}.merge(opts || {})
      RestClient.get(uri, opts, *args)
    end

    #
    # Global config
    #

    global_option '-l', '--rhlogin login', "OpenShift login"
    global_option '-p', '--password password', "OpenShift password"
    global_option '-d', '--debug', "Turn on debugging"

    global_option('--timeout seconds', Integer, 'Set the timeout in seconds for network commands') do |value|
      # FIXME: Refactor so we don't have to use a global var here
      $rest_timeout = value
    end
    global_option '--noprompt', "Suppress the interactive setup wizard from running before a command"
    global_option '--config FILE', "Path of a different config file"
    def config
      raise "Operations requiring configuration must define a config accessor"
    end

    def openshift_server
      config.get_value('libra_server')
    end
    def openshift_url
      "https://#{openshift_server}"
    end
    def openshift_rest_node
      "#{openshift_url}/broker/rest/api"
    end

    #
    # Output helpers
    #

    def debug(msg)
      $stderr.puts "DEBUG: #{msg}" if debug?
    end

    def deprecated_command(correct,short = false)
      deprecated("This command is deprecated. Please use '#{correct}' instead.",short)
    end

    def deprecated_option(deprecated,new)
      deprecated("The option '#{deprecated}' is deprecated. Please use '#{new}' instead")
    end

    def deprecated(msg,short = false)
      HighLine::use_color = false if windows? # handle deprecated commands that does not start through highline

      info = " For porting and testing purposes you may switch this %s to %s by setting the DISABLE_DEPRECATED environment variable to %d.  It is not recommended to do so in a production environment as this option may be removed in future releases."

      msg << info unless short
      if RHC::Helpers.disable_deprecated?
        raise DeprecatedError.new(msg % ['an error','a warning',0])
      else
        warn "Warning: #{msg}\n" % ['a warning','an error',1]
      end
    end

    def say(msg, *args)
      if Hash[*args][:stderr]
        $stderr.puts msg
      else
        super(msg)
      end
      msg
    end

    def success(msg, *args)
      say color(msg, :green), *args
    end

    def info(msg, *args)
      say color(msg, :cyan), *args
    end

    def warn(msg, *args)
      say color(msg, :yellow), *args
    end

    def error(msg, *args)
      say color(msg, :red), *args
    end

    def color(s, color)
      $terminal.color(s, color)
    end

    def pluralize(count, s)
      count == 1 ? "#{count} #{s}" : "#{count} #{s}s"
    end

    def table(items, opts={}, &block)
      items = items.map &block if block_given?
      columns = []
      max = items.each do |item|
        item.each_with_index do |s, i|
          item[i] = s.to_s
          columns[i] = [columns[i] || 0, s.length].max if s.respond_to?(:length)
        end
      end
      align = opts[:align] || []
      join = opts[:join] || ' '
      items.map do |item|
        item.each_with_index.map{ |s,i| s.send((align[i] == :right ? :rjust : :ljust), columns[i], ' ') }.join(join).strip
      end
    end

    # This will format table headings for a consistent look and feel
    #   If a heading isn't explicitly defined, it will attempt to look up the parts
    #   If those aren't found, it will capitalize the string
    def table_heading(value)
      # Set the default proc to look up undefined values
      headings = Hash.new do |hash,key|
        items = key.to_s.split('_')
        # Look up each piece individually
        hash[key] = items.length > 1 ?
          # Recusively look up the heading for the parts
          items.map{|x| headings[x.to_sym]}.join(' ') :
          # Capitalize if this part isn't defined
          items.first.capitalize
      end

      # Predefined headings (or parts of headings)
      headings.merge!({
        :creation_time  => "Created",
        :uuid           => "UUID",
        :current_scale  => "Current",
        :scales_from    => "Minimum",
        :scales_to      => "Maximum",
        :url            => "URL",
        :ssh            => "SSH",
        :gear_profile   => "Gear Size"
      })

      headings[value]
    end

    def header(s,opts = {})
      @indent ||= 0
      indent s
      indent "="*s.length
      if block_given?
        @indent += 1
        yield
        @indent -= 1
      end
    end

    INDENT = 2
    def indent(str)
      @indent ||= 0
      say "%s%s" % [" " * @indent * INDENT,str]
    end

    ##
    # section
    #
    # highline helper mixin which correctly formats block of say and ask
    # output to have correct margins.  section remembers the last margin
    # used and calculates the relitive margin from the previous section.
    # For example:
    #
    # section(bottom=1) do
    #   say "Hello"
    # end
    #
    # section(top=1) do
    #   say "World"
    # end
    #
    # Will output:
    #
    # > Hello
    # >
    # > World 
    #
    # with only one newline between the two.  Biggest margin wins.
    #
    # params:
    #  top - top margin specified in lines
    #  bottom - bottom margin specified in line
    #
    @@section_bottom_last = 0
    def section(params={}, &block)
      top = params[:top]
      top = 0 if top.nil?
      bottom = params[:bottom]
      bottom = 0 if bottom.nil?

      # add more newlines if top is greater than the last section's bottom margin
      top_margin = @@section_bottom_last

      # negitive previous bottoms indicate that an untracked newline was
      # printed and so we do our best to negate it since we can't remove it
      if top_margin < 0
        top += top_margin
        top_margin = 0
      end

      until top_margin >= top
        say "\n"
        top_margin += 1
      end

      block.call

      bottom_margin = 0
      until bottom_margin >= bottom
        say "\n"
        bottom_margin += 1
      end

      @@section_bottom_last = bottom
    end

    ##
    # paragraph
    #
    # highline helper which creates a section with margins of 1, 1
    #
    def paragraph(&block)
      section(:top => 1, :bottom => 1, &block)
    end

    ##
    # results
    #
    # highline helper which creates a paragraph with a header
    # to distinguish the final results of a command from other output
    #
    def results(&block)
      paragraph do
        say "RESULT:"
        yield
      end
    end

    # Platform helpers
    def jruby? ; RUBY_PLATFORM =~ /java/i end
    def windows? ; RUBY_PLATFORM =~ /win(32|dows|ce)|djgpp|(ms|cyg|bcc)win|mingw32/i end
    def unix? ; !jruby? && !windows? end

    # common SSH key display format in ERB
    def ssh_key_display_format
      ERB.new <<-FORMAT
       Name: <%= key.name %>
       Type: <%= key.type %>
Fingerprint: <%= key.fingerprint %>

      FORMAT
    end

    #
    # Check if host exists
    #
    def host_exists?(host)
      # :nocov:
      # Patch for BZ840938 to support Ruby 1.8 on machines without /etc/resolv.conf
      dns = Resolv::DNS.new((Resolv::DNS::Config.default_config_hash || {}))
      dns.getresources(host, Resolv::DNS::Resource::IN::A).any?
      # :nocov:
    end
  end
end
