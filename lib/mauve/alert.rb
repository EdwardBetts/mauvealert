require 'mauve/proto'
require 'mauve/alert_changed'
require 'mauve/history'
require 'mauve/datamapper'
require 'mauve/source_list'
require 'sanitize'

module Mauve
  #
  # This is a view of the Alert table, which allows easy finding of the next
  # alert due to trigger.
  #
  class AlertEarliestDate
 
    include DataMapper::Resource
    
    property :alert_id, Integer
    property :earliest, EpochTime
    belongs_to :alert, :model => "Alert"
    
    # 1) Shame we can't get this called automatically from DataMapper.auto_upgrade!
    #
    # 2) Can't use a neater per-connection TEMPORARY VIEW because the pooling 
    # function causes the connection to get dropped occasionally, and we can't
    # hook the reconnect function (that I know of).
    #
    # http://www.mail-archive.com/datamapper@googlegroups.com/msg02314.html
    #
    def self.create_view!
      the_distant_future = (Time.now + 2000.days).to_i # it is the year 2000 - the humans are dead

      case DataMapper.repository(:default).adapter.class.to_s
        when "DataMapper::Adapters::PostgresAdapter" 
          ifnull = "COALESCE"
          min    = "LEAST"
        else 
          ifnull = "IFNULL"
          min    = "MIN"
      end

      ["BEGIN TRANSACTION",
       "DROP VIEW IF EXISTS mauve_alert_earliest_dates",
       "CREATE VIEW 
          mauve_alert_earliest_dates
        AS
        SELECT 
          id AS alert_id,
          NULLIF(
            #{min}(
              #{ifnull}(will_clear_at, #{the_distant_future}),
              #{ifnull}(will_raise_at, #{the_distant_future}),
              #{ifnull}(will_unacknowledge_at,  #{the_distant_future})
            ),
            #{the_distant_future}
          ) AS earliest
        FROM mauve_alerts 
        WHERE
          will_clear_at IS NOT NULL OR
          will_raise_at IS NOT NULL OR
          will_unacknowledge_at IS NOT NULL
      ",
      "END TRANSACTION"].each do |statement|
        repository(:default).adapter.execute(statement.gsub(/\s+/, " "))
      end
    end
  end
 
  #
  # Woo! An alert.
  #
  class Alert
    # @deprecated Not used anymore?
    def bytesize; 99; end
    # @deprecated Not used anymore?
    def size; 99; end
    
    include DataMapper::Resource
   
    #
    # If a string matches this regex, it is valid UTF8.
    #
    UTF8_REGEXP = Regexp.new(/^(?:#{[
         "[\x00-\x7F]",                        # ASCII
         "[\xC2-\xDF][\x80-\xBF]",             # non-overlong 2-byte
         "\xE0[\xA0-\xBF][\x80-\xBF]",         # excluding overlongs
         "[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}",  # straight 3-byte
         "\xED[\x80-\x9F][\x80-\xBF]",         # excluding surrogates
         "\xF0[\x90-\xBF][\x80-\xBF]{2}",      # planes 1-3
         "[\xF1-\xF3][\x80-\xBF]{3}",          # planes 4-15
         "\xF4[\x80-\x8F][\x80-\xBF]{2}"       # plane 16
        ].join("|")})*$/)
    
    property :id, Serial
    property :alert_id, String, :required => true, :unique_index => :alert_index, :length=>256, :lazy => false
    property :source, String, :required => true, :unique_index => :alert_index, :length=>512, :lazy => false
    property :subject, String, :length=>512, :lazy => false
    property :summary, String, :length=>1024, :lazy => false
    property :detail, Text, :length=>65535
    property :importance, Integer, :default => 50

    property :raised_at, EpochTime
    property :cleared_at, EpochTime
    property :updated_at, EpochTime
    property :acknowledged_at, EpochTime
    property :acknowledged_by, String, :lazy => false
    property :update_type, String, :lazy => false
    
    property :will_clear_at, EpochTime
    property :will_raise_at, EpochTime
    property :will_unacknowledge_at, EpochTime

    property :cached_alert_group, String

    has n, :changes, :model => AlertChanged
    has n, :histories, :through => :alerthistory

    has 1, :alert_earliest_date

    before :valid?, :do_set_timestamps
    before :save, :do_sanitize_html
    before :save, :take_copy_of_changes

    after  :save, :notify_if_needed
    after  :destroy, :destroy_associations

    validates_with_method :check_dates
    
    default_scope(:default).update(:order => [:source, :importance])
    
    # @return [String]
    def to_s 
      "#<Alert #{id}, alert_id #{alert_id}, source #{source}>"
    end

    # @return [Log4r::Logger] the logger instance.
    def logger
      @logger ||= self.class.logger
    end

    # @deprecated Not sure if this is used any more.
    #
    # @param [Integer] Seconds 
    #
    # @return [String]
    def time_relative(secs)
      secs = secs.to_i.abs
      case secs
        when 0..59 then "just now"
        when 60..3599 then "#{secs/60}m ago"
        when 3600..86399 then "#{secs/3600}h ago"
        else
          days = secs/86400
          days == 1 ? "yesterday" : "#{secs/86400} days ago"
      end
    end

    #
    # @return [Mauve::AlertGroup] The first matching AlertGroup for this alert
    def alert_group
      # 
      # Find the AlertGroup by name if we've got a cached value
      #
      alert_group = AlertGroup.find{|a| self.cached_alert_group == a.name} if self.cached_alert_group

      if alert_group.nil?
        #
        # If we've not found the alert group by name look for it again, the
        # proper way.
        #
        alert_group = AlertGroup.find{|a| a.includes?(self)}
        alert_group = AlertGroup.all.last if alert_group.nil?
        self.cached_alert_group = alert_group.name unless alert_group.nil?
      end
      
      alert_group 
    end

    # Pick out the source lists that match this alert by subject.
    #
    # @return [Array] All the SourceList matches
    def source_lists
      Mauve::Configuration.current.source_lists.collect{|label, list| self.in_source_list?(label) ? label : nil}.compact
    end

    # Checks to see if included in a named source list
    #
    # @param [String] listname
    # @return [Boolean]
    def in_source_list?(listname)
      source_list = Mauve::Configuration.current.source_lists[listname]
      return false unless source_list.is_a?(SourceList)

      host = self.subject

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

      return true if source_list.list.any? do |l|
        case l
          when String
            host == l
          when Regexp
            host =~ l
          when IPAddr 
            begin
              l.include?(IPAddr.new(host))
            rescue ArgumentError => err
              # rescue random IPAddr argument errors
              false
            end
          else
            false
        end
      end

      return false unless source_list.list.any?{|l| l.is_a?(IPAddr)}

      @subject_ips ||= MauveResolv.get_ips_for(host).collect{|i| IPAddr.new(i)}

      return false if @subject_ips.nil? or @subject_ips.empty?

      return source_list.list.select{|i| i.is_a?(IPAddr)}.any? do |list_ip| 
        @subject_ips.any?{|ip| list_ip.include?(ip)}
      end
      
      return false
    end

    # Returns the alert level 
    #
    # @return [Symbol] The alert level, as per its AlertGroup.
    def level
      @level ||= self.alert_group.level
    end
  
    # An array used to sort compare
    # 
    # @return [Array] 
    def sort_tuple
      [AlertGroup::LEVELS.index(self.level), (self.raised_at || self.cleared_at || Time.now)]
    end

    # Comparator.  Uses sort_tuple to compare with another alert
    #
    # @param [Mauve::Alert] other Other alert
    #
    # @return [Integer]
    def <=>(other)
      other.sort_tuple <=> self.sort_tuple
    end
 
    # The alert subject
    #
    # @return [String]
    def subject; attribute_get(:subject) || attribute_get(:source) || "not set" ; end

    # The alert detail
    # 
    # @return [String]
    def detail;  attribute_get(:detail)  || "_No detail set._" ; end

    #
    # Set the subject -- this clears the cached_alert_group.
    #
    def subject=(s)
      self.cached_alert_group = nil
      @subject_ips = nil
      attribute_set(:subject, s)
    end 

    #
    # Set the detail -- this clears the cached_alert_group.
    #
    def detail=(s)
      self.cached_alert_group = nil
      attribute_set(:detail, s)
    end

    # 
    # Set the source -- this clears the cached_alert_group.
    #
    def source=(s)
      self.cached_alert_group = nil
      attribute_set(:source, s)
    end 
    
    #
    # Set the summary -- this clears the cached_alert_group.
    #
    def summary=(s)
      self.cached_alert_group = nil
      attribute_set(:summary, s)
    end
 
    protected

    # This cleans the HTML before saving.
    #
    def do_sanitize_html
      html_permitted_in = [:detail]

      attributes.each do |key, val|
        next if html_permitted_in.include?(key)
        next unless attribute_dirty?(key)
        next unless val.is_a?(String)

        attribute_set(key, Alert.remove_html(val))
      end

      attributes.each do |key, val|
        next unless html_permitted_in.include?(key)
        next unless attribute_dirty?(key)
        next unless val.is_a?(String)

        attribute_set(key, Alert.clean_html(val))
      end
    end

    def do_set_timestamps(context = :default)
      self.updated_at = Time.now unless self.original_attributes.has_key?("updated_at")
    end
   
    # This is to stop datamapper inserting duff dates into the database.
    #
    def check_dates
      bad_dates = self.attributes.find_all do |key, value|
        value.is_a?(Time) and (value < (Time.now - 3650.days) or value > (Time.now + 3650.days))
      end

      if bad_dates.empty?
        true
      else
        [ false, "The dates "+bad_dates.collect{|k,v| "#{v.to_s} (#{k})"}.join(", ")+" are invalid." ]
      end
    end

    # This allows us to take a copy of the changes before we save.
    #
    def take_copy_of_changes
      @attributes_before_save = Hash.new
      self.original_attributes.each do |k,v| 
        @attributes_before_save[k.name] = v
      end
    end

    # This sends notifications.  It is called after each save.
    #
    # @return [Boolean] 
    def notify_if_needed
      #
      # Make sure we don't barf
      #
      @attributes_before_save ||= Hash.new

      is_a_new_alert = @attributes_before_save.values.all?{|a| a.nil?}
      #
      # Do not alert about changes, for now.
      #
      is_a_change    = false # [:subject, :summary].any?{|k| @attributes_before_save.keys.include?(k)}

      #
      # We notify if the update type has changed (but not from nil), or if the update type is
      # "raised", and the above is_a_change condition is true
      #
      if (@attributes_before_save.has_key?(:update_type) and !is_a_new_alert) or
         (self.update_type == "raised" and (is_a_new_alert or is_a_change))

        self.notify

        h = History.new(:alerts => [self], :type => "update")

        if self.update_type == "acknowledged"
          h.event = "ACKNOWLEDGED until #{self.will_unacknowledge_at}"
          h.user  = self.acknowledged_by

        elsif is_a_change
          h.event = "CHANGED: "
          h.event += @attributes_before_save.keys.collect{|k| "#{k.to_s}: #{@attributes_before_save[k]} -> #{self.__send__(k)}"}.join(", ") 

        else
          h.event = self.update_type.upcase

        end

        if !h.save
          logger.error "Unable to save history due to #{h.errors.inspect}"
        end
      end

      true
    end

    #
    # 
    #

    # Remove all history for an alert, when an alert is destroyed.
    #
    #
    def destroy_associations
      AlertHistory.all(:alert_id => self.id).destroy
    end

    public
    
    # Send a notification for this alert.
    #
    # @return [Boolean] Showing if an alert has been sent.
    def notify(at = Time.now)
      Server.notification_push([self, at])
    end

    # Acknowledge an alert
    #
    # @param [Mauve::Person] person The person acknowledging the alert
    # @param [Time] ack_until The time when the alert should unacknowledge
    #
    # @return [Boolean] showing the acknowledgment has been successful
    def acknowledge!(person, ack_until = Time.now+3600)
      raise ArgumentError unless person.is_a?(Person)
      raise ArgumentError unless ack_until.is_a?(Time)
      raise ArgumentError, "Cannot acknowledge a cleared alert" if self.cleared?

      #
      # Limit acknowledgment time.
      #
      limit = Time.now + Configuration.current.max_acknowledgement_time
      ack_until = limit if ack_until > limit
 
      self.acknowledged_by = person.username
      self.acknowledged_at = Time.now
      self.will_unacknowledge_at = ack_until
      self.update_type = "acknowledged"

      #
      # Re-cache the alert group.
      #
      self.cached_alert_group = nil
      self.alert_group

      unless save
        logger.error("Couldn't save #{self}") 
        false
      else
        true
      end
    end
    
    # Unacknowledge an alert
    #
    # @return [Boolean] showing the unacknowledgment has been successful
    def unacknowledge!
      self.acknowledged_by = nil
      self.acknowledged_at = nil
      self.will_unacknowledge_at = nil
      self.update_type = (raised? ? "raised" : "cleared")

      unless save
        logger.error("Couldn't save #{self}") 
        false
      else
        true
      end
    end
   
    # Raise an alert at a specified time
    #    
    # @param [Time] at The time at which the alert should be raised.
    #
    # @return [Boolean] showing the raise has been successful
    def raise!(at = Time.now)
      #
      # OK if this is an alert updated in the last run, do not raise, just postpone.
      #
      if (self.will_raise_at or self.will_unacknowledge_at) and
          Server.instance.in_initial_sleep? and 
          self.updated_at and
          self.updated_at < Server.instance.started_at

        postpone_until = Server.instance.started_at + Server.instance.initial_sleep

        if self.will_raise_at and self.will_raise_at <= Time.now
          self.will_raise_at = postpone_until
        end

        if self.will_unacknowledge_at and self.will_unacknowledge_at <= Time.now
          self.will_unacknowledge_at = postpone_until
        end
        
        logger.info("Postponing raise of #{self} until #{postpone_until} as it was last updated in a prior run of Mauve.")
      else
        self.acknowledged_by = nil
        self.acknowledged_at = nil
        self.will_unacknowledge_at = nil
        self.raised_at = at if self.raised_at.nil?
        self.will_raise_at = nil
        self.cleared_at = nil
        # Don't clear will_clear_at
        self.update_type = "raised" if self.update_type.nil? or self.update_type != "changed" or self.original_attributes[Alert.properties[:update_type]] == "cleared"

        #
        # Find the alert group to allow it to be cached.
        #
        self.cached_alert_group = nil
        self.alert_group
      end

      unless save
        logger.error("Couldn't save #{self}") 
        false
      else
        true
      end
    end

    # Clear an alert at a specified time
    #    
    # @param [Time] at The time at which the alert should be cleared.
    #
    # @return [Boolean] showing the clear has been successful
    def clear!(at = Time.now)
      #
      # Postpone clearance if we're in the sleep period.
      #
      if self.will_clear_at and
          Server.instance.in_initial_sleep? and 
          self.updated_at and
          self.updated_at < Server.instance.started_at
        
        self.will_clear_at = Server.instance.started_at + Server.instance.initial_sleep

        logger.info("Postponing clear of #{self} until #{self.will_clear_at} as it was last updated in a prior run of Mauve.")
      else
        self.acknowledged_by = nil
        self.acknowledged_at = nil
        self.will_unacknowledge_at = nil
        self.raised_at = nil
        # Don't clear will_raise_at
        self.cleared_at = at if self.cleared_at.nil?
        self.will_clear_at = nil
        self.update_type = "cleared"
        #
        # Un-cache the alert group
        #
        self.cached_alert_group = nil
      end

      if save
        #
        # Clear all reminders.
        #
        self.changes.all(:remind_at.not => nil, :at.lte => at, :update_type => "raised").each do |ac|
          ac.remind_at = nil
          ac.save
        end

        #
        # Return true.
        #
        true
      else
        #
        # Oops.
        #
        logger.error("Couldn't save #{self}") 
        false
      end
    end
      
    # The next time this alert should be polled, either to raise, clear, or
    # unacknowledge, or nil if nothing is due.
    #
    # @return [Time, NilClass]
    def due_at
      [will_clear_at, will_raise_at, will_unacknowledge_at].compact.sort.first
    end
    
    # Polls the alert, raising or clearing as needed.
    #
    # @return [Boolean] showing the poll was successful
    def poll
      logger.debug("Polling #{self.to_s}")
      if (will_unacknowledge_at and will_unacknowledge_at <= Time.now) or
        (will_raise_at and will_raise_at <= Time.now)
        raise!
      elsif will_clear_at && will_clear_at <= Time.now
        clear!
      else
        true
      end
    end


    # Is the alert raised?
    #
    # @return [Boolean]
    def raised?
      !raised_at.nil? and (cleared_at.nil? or raised_at > cleared_at)
    end

    # Is the alert acknowledged?
    #
    # @return [Boolean]
    def acknowledged?
      !acknowledged_at.nil?
    end

    # Is the alert cleared? Cleared is just the opposite of raised.
    #
    # @return [Boolean]
    def cleared?
      !raised?
    end
 
    class << self

      # Removes or cleans HTML from a string
      #
      #
      # @param  [String] str   String to clean
      # @param  [Hash]   conf  Sanitize::Config thingy
      # @return [String]
      def remove_html(str, conf = Sanitize::Config::DEFAULT)
        raise ArgumentError, "Expected a string, got a #{str.class}" unless str.is_a?(String)
        str = clean_utf8(str)

        if str =~ /<[^0-9 <&.-]/
          Sanitize.clean( str, conf )
        else
          str
        end
      end

      # Cleans HTML in a string, removing dangerous elements/contents.
      #
      # @param  [String] str String to clean
      # @return [String]
      def clean_html(str)
        str = clean_utf8(str)
        remove_html(str, Sanitize::Config::RELAXED.merge({:remove_contents => true}))
      end

      def clean_utf8(str)
        unless UTF8_REGEXP.match(str)
          str.gsub(/[^\x00-\x7F]/,'?')
        else
          str
        end
      end

      # All alerts currently raised
      #
      # @return [Array]
      def all_raised
        all(:raised_at.not => nil, :order => [:raised_at.asc]) & (all(:cleared_at => nil) | all(:raised_at.gte => :cleared_at))
      end
      
      # All alerts currently raised and unacknowledged
      #
      # @return [Array]
      def all_unacknowledged
        all_raised - all_acknowledged
      end

      # All alerts currently acknowledged
      #
      # @return [Array]
      def all_acknowledged
        all(:acknowledged_at.not => nil)
      end

      # All alerts currently cleared
      #
      # @return [Array]
      def all_cleared
        all - all_raised - all_acknowledged
      end

      # Returns a hash of all the :urgent, :normal and :low alerts.
      #
      # @return [Hash] A hash with the relevant alerts per level
      def get_all ()
        hash = Hash.new
        hash[:urgent] = Array.new
        hash[:normal] = Array.new
        hash[:low] = Array.new
        all().each do |iter|
          next if true == iter.cleared?
          hash[AlertGroup.matches(iter)[0].level] << iter
        end
        return hash
      end

      # Find the next Alert that will have a timed action due on it, or nil if
      # none are pending.
      #
      # @return [Mauve::Alert, Nilclass]
      def find_next_with_event
        earliest_alert = AlertEarliestDate.first(:order => [:earliest])
        earliest_alert ? earliest_alert.alert : nil
      end

      # @deprecated Not sure this is used any more.
      #
      # @return [Array]
      def all_overdue(at = Time.now)
        AlertEarliestDate.all(:earliest.lt => at, :order => [:earliest]).collect do |earliest_alert|
          earliest_alert ? earliest_alert.alert : nil
        end
      end
     
      # Receive an AlertUpdate buffer from the wire.
      #
      # @param [String] update The update string, as received over UDP
      # @param [Time] reception_time The time the update was received
      # @param [String] ip_source The IP address of the source of the update
      #
      # @return [NilClass]
      def receive_update(update, reception_time = Time.now, ip_source="network")

        unless update.kind_of?(Proto::AlertUpdate)
          new_update = Proto::AlertUpdate.new
          new_update.parse_from_string(update)
          update = new_update
        end

        alerts_updated = []
        
        # logger.debug("Alert update received from wire: #{update.inspect.split("\n").join(" ")}")
        
        #
        # Transmission time helps us determine any time offset
        #
        if update.transmission_time and update.transmission_time > 0
          transmission_time = Time.at(update.transmission_time) 
        else
          transmission_time = reception_time
        end

        time_offset = (reception_time - transmission_time).round

        #
        # Make sure there is no HTML in the update source.  Need to do this
        # here because we use the html-free version in the database save hook. 
        #
        update.source = Alert.remove_html(update.source.to_s)

        # Update each alert supplied
        #
        update.alert.each do |alert|
          # 
          # Infer some actions from our pure data structure (hmm, wonder if
          # this belongs in our protobuf-derived class?
          #
          clear_time = alert.clear_time == 0 ? nil : Time.at(alert.clear_time + time_offset)
          raise_time = alert.raise_time == 0 ? nil : Time.at(alert.raise_time + time_offset)

          if raise_time.nil? && clear_time.nil?
            #
            # Make sure that we raise if neither raise nor clear is set
            #
            raise_time = reception_time 
          end

          #
          # Make sure there's no HTML in the ID -- we need to do this here
          # because of the database save hook will clear it out, causing this
          # search to fail.
          #
          alert.id = Alert.remove_html(alert.id.to_s)
 
          alert_db = first(:alert_id => alert.id, :source => update.source) ||
            new(:alert_id => alert.id, :source => update.source)

          ##
          #
          # Work out if we're raising now, or in the future.
          #
          # Allow a 5s offset in timings.
          #
          if raise_time
            if raise_time <= (reception_time + 5)
              #
              # Don't reset the raised_at time if the alert is already raised.
              # This prevents the raised time constantly changing on alerts
              # that are already raised.
              #
              alert_db.raised_at     = raise_time if alert_db.raised_at.nil?
              alert_db.will_raise_at = nil
            else
              alert_db.raised_at     = nil
              alert_db.will_raise_at = raise_time
            end
          end

          if clear_time
            if clear_time <= (reception_time + 5)
              #
              # Don't reset the cleared_at time (see above for raised_at timings).
              #
              alert_db.cleared_at    = clear_time if alert_db.cleared_at.nil?
              alert_db.will_clear_at = nil
            else
              alert_db.cleared_at    = nil
              alert_db.will_clear_at = clear_time
            end
          end

          #
          # Set the subject
          #
          if alert.subject and !alert.subject.empty? 
            alert_db.subject = alert.subject

          elsif alert_db.subject.nil? 
            #
            # Use the source, Luke, but only when the subject hasn't already been set.
            #
            alert_db.subject = alert_db.source
          end

          alert_db.summary = alert.summary if alert.summary && !alert.summary.empty?

          alert_db.detail = alert.detail   if alert.detail  && !alert.detail.empty?

          alert_db.importance = alert.importance if alert.importance != 0 

          alert_db.updated_at = reception_time

          if alert_db.raised? 
            #
            # If we're acknowledged, just save.
            #
            if alert_db.acknowledged?
              alert_db.save
            else
              alert_db.raise! 
            end
          else
            alert_db.clear!
          end

          #
          # Record the fact we received an update.
          #
          logger.info("Received update from #{ip_source} for #{alert_db}")

        end
        
        # If this is a complete replacement update, find the other alerts
        # from this source and clear them.
        #
        if update.replace
          alert_ids_mentioned = update.alert.map { |alert| alert.id }
          logger.info "Replacing all alerts from #{update.source} except "+alert_ids_mentioned.join(",")
          all(:source => update.source, 
              :alert_id.not => alert_ids_mentioned,
              :cleared_at => nil
              ).each do |alert_db|
            alert_db.clear!
          end
        end
      
        return nil 
      end

      #
      # @return [Log4r::Logger] The class logger
      def logger
        Log4r::Logger.new(self.to_s)
      end
    end
  end
end
