# coding: utf-8

require 'rufus-scheduler'

module Lita
  module Handlers
    class LunchReminder < Handler
      on :loaded, :load_on_start

      def initialize(robot)
        super
        @assigner = Lita::Services::LunchAssigner.new(redis)
      end

      def self.help_msg(route)
        { "lunch-reminder: #{t("help.#{route}.usage")}" => t("help.#{route}.description") }
      end

      def load_on_start(_payload)
        create_schedule
      end
      route(/gracias/i, command: true, help: help_msg(:thanks)) do |response|
        response.reply(t(:yourwelcome, subject: response.user.mention_name))
      end
      route(/^está?a? (listo|servido) el almuerzo/i, help: help_msg(:lunch_served)) do
        message = t(:dinner_is_served)
        notify @assigner.winning_lunchers_list, message
      end
      route(/qué?e? hay de postre/i, help: help_msg(:dessert)) do |response|
        response.reply(t(:"todays_dessert#{1 + rand(4)}"))
      end
      route(/qué?e? hay de almuerzo/i, help: help_msg(:menu)) do |response|
        response.reply(t(:todays_lunch))
      end
      route(/por\sfavor\sconsidera\sa\s([^\s]+)\s(para|en) (el|los) almuerzos?/,
        command: true, help: help_msg(:consider_user)) do |response|
        mention_name = mention_name_from_response(response)
        success = @assigner.add_to_lunchers(mention_name)
        if success
          response.reply(t(:will_ask_daily, subject: mention_name))
        else
          response.reply(t(:already_considered, subject: mention_name))
        end
      end
      route(/por\sfavor\sconsidé?e?rame\s(para|en) los almuerzos/i,
        command: true, help: help_msg(:consider_me)) do |response|
        success = @assigner.add_to_lunchers(response.user.mention_name)
        if success
          response.reply(t(:will_ask_you_daily))
        else
          response.reply(t(:already_considered_you, subject: response.user.mention_name))
        end
      end
      route(/por\sfavor\sya\sno\sconsideres\sa\s([^\s]+)\s(para|en) (el|los) almuerzos?/i,
        command: true, help: help_msg(:not_consider_user)) do |response|
        mention_name = mention_name_from_response(response)
        @assigner.remove_from_lunchers(mention_name)
        response.reply(t(:thanks_for_answering))
      end
      route(/^sí$|^hoy almuerzo aqu(í|i)$|^si$/i,
        command: true, help: help_msg(:confirm_yes)) do |response|
        @assigner.add_to_current_lunchers(response.user.mention_name)
        @assigner.add_to_winning_lunchers(response.user.mention_name) if @assigner.already_assigned?
        lunchers = @assigner.current_lunchers_list.length
        case lunchers
        when 1
          response.reply(t(:current_lunchers_one))
        else
          response.reply(t(:current_lunchers_some, subject: lunchers))
        end
      end
      route(/no almuerzo/i, command: true, help: help_msg(:confirm_no)) do |response|
        @assigner.remove_from_current_lunchers response.user.mention_name
        response.reply(t(:thanks_for_answering))
        @assigner.remove_from_winning_lunchers response.user.mention_name
      end

      route(/tengo un invitado/i, command: true) do |response|
        if @assigner.add_to_winning_lunchers(response.user.mention_name) &&
            @assigner.add_to_winning_lunchers("invitado_de_#{response.user.mention_name}")
          response.reply(t(:friend_added, subject: response.user.mention_name))
        else
          response.reply("tu amigo no cabe wn")
        end
      end

      route(/tengo una invitada/i, command: true) do |response|
        response.reply("es rica?")
      end

      route(/qui(é|e)nes almuerzan hoy/i, help: help_msg(:show_today_lunchers)) do |response|
        unless @assigner.already_assigned?
          response.reply("Aun no lo se pero van #{@assigner.current_lunchers_list.count} interesados.")
          next
        end
        case @assigner.winning_lunchers_list.length
        when 0
          response.reply(t(:no_one_lunches))
        when 1
          response.reply(t(:only_one_lunches, subject: @assigner.winning_lunchers_list[0]))
        when 2
          response.reply(t(:dinner_for_two,
            subject1: @assigner.winning_lunchers_list[0],
            subject2: @assigner.winning_lunchers_list[1]))
        else
          response.reply(t(:current_lunchers_list,
            subject1: @assigner.winning_lunchers_list.length,
            subject2: @assigner.winning_lunchers_list.join(', ')))
        end
      end

      route(/qui(é|e)n(es)? ((cooper(o|ó|aron))|(cag(o|ó|aron))|(qued(o|ó|aron)) afuera) ((del|con el) almuerzo)? (hoy)?\??/i,
        help: help_msg(:show_loosing_lunchers)) do |response|
        unless @assigner.already_assigned?
          response.reply("No lo se, pero van #{@assigner.current_lunchers_list.count} interesados.")
          next
        end
        case @assigner.loosing_lunchers_list.length
        when 0
          response.reply('Nadie, estoy de buena hoy dia :)')
        else
          verb = ['perjudiqué a', 'me maletié a', 'cooperó', 'deje afuera a'].sample
          response.reply("Hoy #{verb} #{@assigner.loosing_lunchers_list.join(', ')}")
        end
      end

      route(/qui(é|e)nes est(á|a)n considerados para (el|los) almuerzos?/i,
        help: help_msg(:show_considered)) do |response|
        response.reply(@assigner.lunchers_list.join(', '))
      end

      route(/assignnow/i, command: true) do |response|
        @assigner.do_the_assignment
        response.reply("did it boss")
      end

      route(/cédele mi puesto a ([^\s]+)/i, command: true) do |response|
        unless @assigner.remove_from_winning_lunchers(response.user.mention_name)
          response.reply("no puedes ceder algo que no tienes, amiguito")
          next
        end
        enters = response.matches[0][0]
        @assigner.add_to_winning_lunchers(enters)
        response.reply("tú te lo pierdes, comerá #{enters} por ti")
      end

      def mention_name_from_response(response)
        mention_name = response.matches[0][0]
        mention_name.delete('@') if mention_name
      end

      def refresh
        @assigner.reset_lunchers
        @assigner.lunchers_list.each do |luncher|
          user = Lita::User.find_by_mention_name(luncher)
          message = t(:question, subject: luncher)
          robot.send_message(Source.new(user: user), message) if user
        end
      end

      def notify(list, message)
        list.shuffle.each do |luncher|
          user = Lita::User.find_by_mention_name(luncher)
          robot.send_message(Source.new(user: user), message) if user
        end
      end

      def announce_winners
        notify(@assigner.winning_lunchers_list, "Yeah baby, almuerzas con nosotros!")
        notify(@assigner.loosing_lunchers_list, t(:current_lunchers_too_many))
      end

      def create_schedule
        scheduler = Rufus::Scheduler.new
        scheduler.cron(ENV['ASK_CRON']) do
          refresh
          scheduler.in(ENV['WAIT_RESPONSES_SECONDS'].to_i) do
            @assigner.do_the_assignment
            announce_winners
          end
        end
        scheduler.cron(ENV['PERSIST_CRON']) do
          persist_winning_lunchers
        end
      end

      Lita.register_handler(self)
    end
  end
end
