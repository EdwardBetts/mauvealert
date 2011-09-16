require 'mauve/mauve_thread'
require 'mauve/notifiers'
require 'mauve/notifiers/xmpp'

module Mauve

  # The Notifier is reponsible for popping notifications off the
  # notification_buffer run by the Mauve::Server instance.  This ensures that
  # notifications are sent in a separate thread to the main processing /
  # updating threads, and stops notifications delaying updates.
  #
  #
  class Notifier < MauveThread
    
    include Singleton

    # Stop the notifier thread.  This just makes sure that all the
    # notifications in the buffer have been sent before closing the XMPP
    # connection.
    #
    def stop
      super

      #
      # Flush the queue.
      #
      main_loop

      if Configuration.current.notification_methods['xmpp']
        Configuration.current.notification_methods['xmpp'].close
      end

    end

    private

    # This is the main loop that is executed in the thread.
    #
    #
    def main_loop

      #
      # Make sure we're connected to the XMPP server if needed on every iteration.
      #
      if Configuration.current.notification_methods['xmpp'] and !Configuration.current.notification_methods['xmpp'].ready?
        #
        # Connect to XMPP server
        #
        xmpp = Configuration.current.notification_methods['xmpp']
        xmpp.connect

        Configuration.current.people.each do |username, person|
          # 
          # Ignore people without XMPP stanzas.
          #
          next unless person.xmpp 

          #
          # Can't do this unless we're ready.
          #
          next unless xmpp.ready?

          #
          # For each JID, either ensure they're on our roster, or that we're in
          # that chat room.
          #
          jid = if xmpp.is_muc?(person.xmpp)
            xmpp.join_muc(person.xmpp)
          else
            xmpp.ensure_roster_and_subscription!(person.xmpp)
          end

          Configuration.current.people[username].xmpp = jid unless jid.nil?
        end

      end

      # 
      # Cycle through the buffer.
      #
      sz = Server.notification_buffer_size

      logger.info "Sending #{sz} alerts" if sz > 0

      #
      # Empty the buffer, one notification at a time.
      #
      sz.times do
        person, *args = Server.notification_pop
        
        #
        # Nil person.. that's craaazy too!
        #
        next if person.nil?

        person.send_alert(*args) 
      end
    end

  end

end


