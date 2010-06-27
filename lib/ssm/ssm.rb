module SimpleStateMachine
  
  def event event_name, state_transitions
    @state_machine_definition ||= StateMachineDefinition.new self
    @state_machine_definition.define_event event_name, state_transitions
  end
  
  def state_machine_definition
    @state_machine_definition
  end
  
  class StateMachineDefinition
    
    attr_reader :events

    def initialize subject
      @events  = {}
      @active_record = subject.ancestors.map {|klass| klass.to_s}.include?("ActiveRecord::Base")
      @decorator = if @active_record
        Decorator::ActiveRecord.new(subject)
      else
        Decorator::Base.new(subject)
      end
    end
    
    def define_event event_name, state_transitions
      @events[event_name.to_s] ||= {}
      if @active_record
        @events["#{event_name}!"] ||= {}
      end
      state_transitions.each do |from, to|
        @events[event_name.to_s][from.to_s] = to.to_s
        @events["#{event_name}!"][from.to_s] = to.to_s if @active_record
        @decorator.decorate(from, to, event_name)
      end
    end

  end
  
  module StateMachine
    
    class Base
      def initialize(subject)
        @subject = subject
      end
    
      def next_state(event_name)
        @subject.class.state_machine_definition.events[event_name.to_s][@subject.state]
      end
    
      def transition(event_name)
        if to = next_state(event_name)
          result = yield
          @subject.state = to
          return result
        else
          illegal_event_callback event_name
        end
      end
    
      private

        def illegal_event_callback event_name
          # override with your own implementation, like setting errors in your model
          raise "You cannot '#{event_name}' when state is '#{@subject.state}'"
        end
    
    end

    class ActiveRecord < Base

      def transition(event_name)
        if to = next_state(event_name)
          if  with_error_counting { yield } > 0 || @subject.invalid?
            if event_name =~ /\!$/
              raise ::ActiveRecord::RecordInvalid.new(@subject)
            else
              return false
            end
          else
            @subject.state = to
            if event_name =~ /\!$/
              @subject.save! #TODO maybe save_without_validation!
            else
              @subject.save
            end
          end
        else
          illegal_event_callback event_name
        end
      end

      private
      
        def with_error_counting
          original_errors_size =  @subject.errors.size
          yield
          @subject.errors.size - original_errors_size          
        end

    end

  end

  module Decorator
    class Base

      def initialize(subject)
        @subject = subject
        define_state_machine_method
        define_state_getter_method
        define_state_setter_method
      end

      def decorate from, to, event_name
        define_state_helper_method(from)
        define_state_helper_method(to)
        define_event_method(event_name)
        decorate_event_method(event_name)
      end

      private

        def define_state_machine_method
          @subject.send(:define_method, "state_machine") do
            @state_machine ||= StateMachine::Base.new(self)
          end
        end

        def define_state_helper_method state
          unless @subject.method_defined?("#{state.to_s}?")
            @subject.send(:define_method, "#{state.to_s}?") do
              self.state == state.to_s
            end
          end
        end

        def define_event_method event_name
          unless @subject.method_defined?("#{event_name}")
            @subject.send(:define_method, "#{event_name}") {}
          end
        end

        def decorate_event_method event_name
          # TODO put in transaction for activeRecord?
          unless @subject.method_defined?("with_managed_state_#{event_name}")
            @subject.send(:define_method, "with_managed_state_#{event_name}") do |*args|
              return state_machine.transition(event_name) do
                send("without_managed_state_#{event_name}", *args)
              end
            end
            @subject.send :alias_method, "without_managed_state_#{event_name}", event_name
            @subject.send :alias_method, event_name, "with_managed_state_#{event_name}"
          end
        end

        def define_state_setter_method
          unless @subject.method_defined?('state=')
            @subject.send(:define_method, 'state=') do |new_state|
              @state = new_state.to_s
            end
          end
        end

        def define_state_getter_method
          unless @subject.method_defined?('state')
            @subject.send(:define_method, 'state') do
              @state
            end
          end
        end

    end
    
    class ActiveRecord < Base

      def decorate from, to, event_name
        super from, to, event_name
        unless @subject.method_defined?("#{event_name}!")
          @subject.send(:define_method, "#{event_name}!") do |*args|
            send "#{event_name}", *args
          end
        end
        decorate_event_method("#{event_name}!")
      end
      
      private
      
      def define_state_machine_method
        @subject.send(:define_method, "state_machine") do
          @state_machine ||= StateMachine::ActiveRecord.new(self)
        end
      end

      def define_state_setter_method; end

      def define_state_getter_method; end

    end
    
  end

end