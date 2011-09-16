# encoding: UTF-8
require 'log4r'
require 'ipaddr'
require 'uri'
require 'mauve/mauve_time'
require 'mauve/mauve_resolv'

module Mauve

  # A simple construct to match sources.
  #
  # One can ask if an IPv4, IPv6, hostname or url (match on hostname only) is
  # contained within a list.  If the query is not an IP address, it will be
  # converted into one as the checks are made.
  #
  # Note that the matching is greedy.  When a hostname maps to several IP
  # addresses and only one of tbhose is included in the list, a match 
  # will occur.
  #
  class SourceList 

    attr_reader :label, :list

    ## Default contructor.
    def initialize (label)
      @label            = label
      @last_resolved_at = nil
      @list = []
      @resolved_list = []
    end

    alias username label

    # Adds a source onto the list.
    #
    # The source can be a string, or array of strings.  Each one can be an IPv6
    # or IPv4 address or range, or a hostname.
    #
    # Hostnames can have *, or numeric ranges in their name.  A '*' represents
    # any character except ".".  A range can be specified as 1..4, meaning 1,
    # 2, 3 or 4.
    #
    # e.g.  1.2.3.4/24
    #       2001:dead::beef/64
    #       app1..10.my-customer.com
    #       *.db.my-customer.com
    #
    # Hostnames are also resolved into IP addresses, and re-resolved every 30
    # minutes.
    #
    # @param [String or Array] l The source(s) to add.
    # @return [SourceList]
    #
    def +(l)
      arr = [l].flatten.collect do |h|
        # "*"              means [^\.]+
        # "(\d+)\.\.(\d+)" is expanded to every integer between $1 and $2
        #                  joined by a pipe, e.g. 1..5 means 1|2|3|4|5
        #  "."              is literal, not a single-character match
        if h.is_a?(String) and (h =~ /[\[\]\*]/ or h =~ /(\d+)\.\.(\d+)/)
          Regexp.new(
              h.
              gsub(/(\d+)\.\.(\d+)/) { |a,b|
                ($1.to_i..$2.to_i).collect.join("|")
              }.
              gsub(/\./, "\\.").
              gsub(/\*/, "[0-9a-z\\-]+") +
              "\\.?$")
        elsif h.is_a?(String) and h =~ /^[0-9a-f\.:]+(\/\d+)?$/i
          IPAddr.new(h)
        elsif h.is_a?(String) or h.is_a?(Regexp)
          h
        else
          logger.warn "Cannot add #{h.inspect} to source list #{@label} as it is not a string or regular expression."
          nil
        end
      end.flatten.reject{|h| h.nil?}

      arr.each do |source|
        ##
        # I would use include? here, but IPAddr tries to convert "foreign"
        # classes to intgers, and RegExp doesn't have a to_i method..
        #
        if @list.any?{|e| source.is_a?(e.class) and source == e}
          logger.warn "#{source} is already on the #{self.label} list"
        else
          @list << source
        end
      end

      @resolved_list    = [] 
      @last_resolved_at = nil

      self
    end

    alias add_to_list +

    # @return [Log4r::Logger]
    def logger
      @logger ||= Log4r::Logger.new self.class.to_s
    end

    # 
    # Return whether or not a list contains a source.
    #
    # First the hostname is checked for a URI, using URI#parse, and then the
    # hostname is extracted from there.  If that fails, the original hostname
    # is used.
    #
    # Next we check against our list, including all IPs for any hostnames in
    # that list.
    #
    # If nothing is found, the hostname is then resolved to its IPs, and we
    # check to see if those IPs are in our list. 
    #
    # @param [String] host The host to look for.
    # @return [Boolean]
    def includes?(host)
      #
      # Redo resolution every thirty minutes
      #
      resolve if @resolved_list.empty? or @last_resolved_at.nil? or (Time.now - 1800) > @last_resolved_at

      #
      # Pick out hostnames from URIs.
      #
      if host =~ /^[a-z][a-z0-9+-]+:\/\//
        begin      
          uri = URI.parse(host)
          host = uri.host unless uri.host.nil?
        rescue URI::InvalidURIError => ex
          # ugh
          logger.warn "Did not recognise URI #{host}"
        end
      end

      return true if @resolved_list.any? do |l|
        case l
          when String
            host == l
          when Regexp
            host =~ l
          when IPAddr 
            begin
              l.include?(IPAddr.new(host))
            rescue ArgumentError
              # rescue random IPAddr argument errors
              false
            end
          else
            false
        end
      end

      return false unless @resolved_list.any?{|l| l.is_a?(IPAddr)}

      ips = MauveResolv.get_ips_for(host).collect{|i| IPAddr.new(i)}

      return false if ips.empty?

      return @resolved_list.select{|i| i.is_a?(IPAddr)}.any? do |list_ip| 
        ips.any?{|ip| list_ip.include?(ip)}
      end
      
      return false
    end

    # 
    # Resolve all hostnames in the list to IP addresses.
    #
    # @return [Array] The new list.
    #
    def resolve
      @last_resolved_at = Time.now

      new_list = @list.collect do |host| 
        if host.is_a?(String)
          [host] + MauveResolv.get_ips_for(host).collect{|i| IPAddr.new(i)}
        else
          host
        end
      end
      @resolved_list = new_list.flatten
    end
  end

end
