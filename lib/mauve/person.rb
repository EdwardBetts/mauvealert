# encoding: UTF-8
require 'timeout'
require 'log4r'

module Mauve
  class Person 
  
    attr_reader :username, :password, :urgent, :normal, :low, :email, :sms
    attr_reader :suppressed, :notifications
    attr_reader :notify_when_off_sick, :notify_when_on_holiday

    # Set up a new Person
    #
    def initialize(username)
      @suppressed = false
      @notifications = []

      @username = username
      @password = nil
      @urgent   = @normal = @low  = nil
      @email = @sms = @hipchat = nil
   
      @notify_when_on_holiday = @notify_when_off_sick = false 
    end
  
    # Determines if a user should be notified if they're ill.
    #
    # @return [Boolean]
    #
    def notify_when_off_sick=(arg)
      @notify_when_off_sick = (arg ? true : false)
    end

    # Determines if a user should be notified if they're on their holdiays.
    #
    # @return [Boolean]
    #
    def notify_when_on_holiday=(arg)
      @notify_when_on_holiday = (arg ? true : false)
    end

    # Sets the Proc to call for urgent notifications
    #
    def urgent=(block)
      raise ArgumentError, "urgent expects a block, not a #{block.class}" unless block.is_a?(Proc)
      @urgent = block
    end
 
    # Sets the Proc to call for normal notifications
    #
    def normal=(block)
      raise ArgumentError, "normal expects a block, not a #{block.class}" unless block.is_a?(Proc)
      @normal = block
    end
    
    # Sets the Proc to call for low notifications
    #
    def low=(block)
      raise ArgumentError, "low expects a block, not a #{block.class}" unless block.is_a?(Proc)
      @low = block
    end

    # Sets the email parameter
    #
    #
    def email=(arg)
      raise ArgumentError, "email expects a string, not a #{arg.class}" unless arg.is_a?(String)
      @email = arg
    end

    # Sets the sms parameter
    #
    #
    def sms=(arg)
      raise ArgumentError, "sms expects a string, not a #{arg.class}" unless arg.is_a?(String)
      @sms = arg
    end

    # Sets up the hipchat parameter
    # 
    #
    def hipchat=(arg)
      raise ArgumentError, "hipchat expected a string, not a #{arg.class}" unless arg.is_a?(String)
      @hipchat = arg
    end

    # Sets the password parameter
    #
    #
    def password=(arg)
      raise ArgumentError, "password expected a string, not a #{arg.class}" unless arg.is_a?(String)
      @password=arg
    end

    # @return Log4r::Logger
    def logger ; @logger ||= Log4r::Logger.new self.class.to_s ; end

    # Determines if notifications to the user are currently suppressed
    #
    # @return [Boolean]
    def suppressed? ; @suppressed ; end

    # Works out if a notification should be suppressed.  If no parameters are supplied, it will 
    #
    # @param [Symbol] Level of notification that is being tested
    # @param [Time] Theoretical time of notification
    # @param [Time] Current time.
    # @return [Boolean] If suppression is needed.
    def should_suppress?(level, with_notification_at = nil, now = Time.now)

      self.suppress_notifications_after.any? do |period, number|
        #
        # When testing if the next alert will suppress, we know that if only
        # one alert is needed to suppress, then this function should always
        # return true.
        #
        return true if with_notification_at and number <= 1

        #
        # Here are the previous notifications set to this person in the last period.
        #
        previous_notifications = History.all(
          :user => self.username, :type => "notification", 
          :created_at.gte => now - period, :created_at.lte => now,
          :event.like => '% succeeded',
          :order => :created_at.desc)

        #
        # Defintely not suppressed if no notifications have been found.
        #
        return false if previous_notifications.count == 0

        #
        # If we're suppressed already, we need to check the time of the last alert sent
        #
        if @suppressed

          if with_notification_at.is_a?(Time)
            latest = with_notification_at
          else
            latest = previous_notifications.first.created_at
          end
          
          #
          # We should not suppress this alert if the last one was sent ages ago
          #
          if (now - latest) >= period
            return false
          end 

        else
          #
          # We do not suppress if we can't find a sufficient number of previous alerts
          #
          if previous_notifications.count < (with_notification_at.nil? ? number : number - 1)
            return false
          end

        end

        #
        # If we're at the lowest level, return true now.
        #
        return true if !AlertGroup::LEVELS.include?(level) or AlertGroup::LEVELS.index(level) == 0

        #
        # Suppress this notification if all the last N of the preceeding
        # notifications were of a equal or higher level.
        #
        return previous_notifications.first(number).alerts.to_a.all? do |a|
          AlertGroup::LEVELS.index(a.level) >= AlertGroup::LEVELS.index(level)
        end

      end
    end
   
    #
    # 
    #
    def suppress_notifications_after 
      @suppress_notifications_after ||= { } 
    end

    # This class implements an instance_eval context to execute the blocks
    # for running a notification block for each person.
    # 
    class NotificationCaller

      # Set up the notification caller
      #
      # @param [Mauve::Person] person
      # @param [Mauve::Alert] alert
      # @param [Array] other_alerts
      # @param [Hash] base_conditions
      #
      def initialize(person, alert, other_alerts, base_conditions={})
        @person = person
        @alert = alert
        @other_alerts = other_alerts
        @base_conditions = base_conditions
      end
      
      # @return Log4r::Logger
      def logger ; @logger ||= Log4r::Logger.new self.class.to_s ; end

      # This method makes sure things like +email+ work.
      #
      # @param [String] name The notification method to use
      # @param [Array or Hash] args Extra conditions to pass to this notification method
      #
      # @return [Boolean] if the notifcation has been successful
      def method_missing(name, *args)
        #
        # Work out the notification method
        #
        notification_method = Configuration.current.notification_methods[name.to_s]

        logger.warn "Notification method '#{name}' not defined  (#{@person.username})" if notification_method.nil?

        #
        # Work out the destination
        #
        if args.first.is_a?(String)
          destination = args.pop
        elsif @person.respond_to?(name)
          destination = @person.__send__(name)
        else
          destination = nil
        end

        logger.warn "#{name} destination for #{@person.username} not set" if destination.nil?

        if args.first.is_a?(Hash)
          conditions  = @base_conditions.merge(args.pop)
        else
          conditions  = @base_conditions
        end


        if notification_method and destination 
          # Methods are expected to return true or false so the user can chain
          # them together with || as fallbacks.  So we have to catch exceptions
          # and turn them into false.
          #
          res = notification_method.send_alert(destination, @alert, @other_alerts, conditions)
        else
          res = false
        end

        #
        # Log the result
        #
        logger.info "#{@alert.update_type.capitalize} #{name} notification to #{@person.username} (#{destination}) " +  (res ? "succeeded" : "failed" ) +" about #{@alert}."

        return res
      end

    end 

    # Sends the alert
    #
    # @param [Symbol] level Level at which the alert should be sent
    # @param [Mauve::Alert] alert Alert we're notifiying about
    #
    # @return [Boolean] if the notification was successful
    def send_alert(level, alert, now=Time.now)

      was_suppressed = @suppressed
      @suppressed    = self.should_suppress?(level)
      will_suppress  = self.should_suppress?(level, now)

      logger.info "Starting to send notifications again for #{username}." if was_suppressed and not @suppressed

      #
      # We only suppress notifications if we were suppressed before we started,
      # and are still suppressed.
      #
      if @suppressed or self.is_on_holiday?(now) or self.is_off_sick?(now)
        note =  "#{alert.update_type.capitalize} #{level} notification to #{self.username} suppressed"
        logger.info note + " about #{alert}."
        History.create(:alerts => [alert], :type => "notification", :event => note, :user => self.username)
        return true 
      end

      result = false

      #
      # Make sure the level we want has been defined as a Proc.
      #
      if __send__(level).is_a?(Proc)
        result = NotificationCaller.new(
          self,
          alert,
          [],
          # current_alerts,
          {:will_suppress  => will_suppress,
           :was_suppressed => was_suppressed, }
        ).instance_eval(&__send__(level))
      end
      
      res = [result].flatten.any?
  
      note = "#{alert.update_type.capitalize} #{level} notification to #{self.username} " +  (res ? "succeeded" : "failed" ) 
      History.create(:alerts => [alert], :type => "notification", :event => note, :user => self.username)

      return res
    end
   
    # 
    # Returns the subset of current alerts that are relevant to this Person.
    #
    # This is currently very CPU intensive, and slows things down a lot.  So
    # I've commented it out when sending notifications.
    #
    # @return [Array] alerts relevant to this person
    def current_alerts
      Alert.all_raised.select do |alert|
        my_last_update = AlertChanged.first(:person => username, :alert_id => alert.id)
        my_last_update && my_last_update.update_type != "cleared"
      end
    end

    # Whether the person is on holiday or not.
    #
    # @return [Boolean] True if person on holiday, false otherwise.
    def is_on_holiday?(at=Time.now)
      return false if self.notify_when_on_holiday

      return CalendarInterface.is_user_on_holiday?(self.username, at)
    end

    def is_off_sick?(at=Time.now)
      return false if self.notify_when_off_sick

      return CalendarInterface.is_user_off_sick?(self.username, at)
    end

    # Returns a list of notification blocks for this person, using the default
    # "during" and "every" paramaters if given.  The "at" and "people_seen"
    # parameters are not used, but are in place to keep the signature the same
    # as the method in people_list.
    # 
    # @paran [Numeric] default_every
    # @param [Block] default_during
    # @param [Time] at The time at which the resolution should take place
    # @param [Array] people_seen A list of people/people_lists already seen.
    # @returns [Array] array of notification blocks.
    #
    def resolve_notifications(default_every=nil, default_during=nil, at = nil, people_seen = [])
      self.notifications.collect do |notification|
        this_notification = Notification.new(self)
        this_notification.every  = default_every  || notification.every
        this_notification.during = default_during || notification.during
        this_notification
      end.flatten.compact
    end

  end

end
