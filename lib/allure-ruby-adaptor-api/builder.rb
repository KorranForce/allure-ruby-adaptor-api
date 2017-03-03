require 'digest'
require 'logger'
require 'mimemagic'
require 'nokogiri'
require 'uuid'
require 'socket'

module AllureRubyAdaptorApi

  class Builder
    class << self
      attr_accessor :suites
      MUTEX = Mutex.new
      HOSTNAME = Socket.gethostname
      LOGGER = Logger.new(STDOUT)

      def start_suite(suite, labels = {:severity => :normal})
        init_suites
        MUTEX.synchronize do
          if self.suites[suite]
            LOGGER.debug "Resuming case_or_suite #{suite} with labels #{labels}"
          else
            LOGGER.debug "Starting case_or_suite #{suite} with labels #{labels}"
            self.suites[suite] = {
                :title => suite,
                :start => timestamp(labels.delete(:start)),
                :tests => {},
                :labels => add_default_labels(labels)
            }
          end
        end
      end

      def stop_suite(title)
        init_suites
        MUTEX.synchronize do
          LOGGER.debug "Stopping case_or_suite #{title}"
          self.suites[title][:stop] = timestamp
        end
      end

      def start_test(suite, test, labels = {:severity => :normal, :start=>Time.now})
        MUTEX.synchronize do
          LOGGER.debug "Starting test #{suite}.#{test} with labels #{labels}"
          self.suites[suite][:tests][test] = {
              :title => test,
              :start => timestamp(labels.delete(:start)),
              :failure => nil,
              :steps => [],
              :attachments => [],
              :labels => add_default_labels(labels),
          }
        end
      end

      def stop_test(suite, test, result = {})
        test_steps = self.suites[suite][:tests][test][:steps]
        test_steps.each do |step|
          if step[:stop].nil? || step[:stop] == 0
            stop_step(suite, test, {:index=>test_steps.index(step), :title=>step[:title]}, result[:status])
          end
        end
        MUTEX.synchronize do
          LOGGER.debug "Stopping test #{suite}.#{test}"
          self.suites[suite][:tests][test][:stop] = timestamp(result[:finished_at])
          self.suites[suite][:tests][test][:start] = timestamp(result[:started_at])
          self.suites[suite][:tests][test][:status] = result[:status]
          if (result[:status].to_sym != :passed)
            self.suites[suite][:tests][test][:failure] = {
                :stacktrace => ((result[:exception] && result[:exception].backtrace) || []).map { |s| s.to_s }.join("\r\n"),
                :message => result[:exception].to_s,
            }
            LOGGER.debug "Failure message: #{self.suites[suite][:tests][test][:failure][:message]}"
            LOGGER.debug "Failure stacktrace: #{self.suites[suite][:tests][test][:failure][:stacktrace]}"
          end

        end
      end

      def start_step(suite, test, step)
        MUTEX.synchronize do
          LOGGER.debug "Starting step #{suite}.#{test}.#{step[:title]}"
          self.suites[suite][:tests][test][:steps][step[:index]] = {
              :title => step[:title],
              :start => timestamp(step[:start]),
              :attachments => []
          }
        end
      end

      def stop_step(suite, test, step, status = :passed)
        MUTEX.synchronize do
          LOGGER.debug "Stopping step #{suite}.#{test}.#{step[:title]}"
          self.suites[suite][:tests][test][:steps][step[:index]][:stop] = timestamp(step[:stop])
          self.suites[suite][:tests][test][:steps][step[:index]][:status] = status
        end
      end

      def add_attachment(suite, test, opts = {:step => nil, :file => nil, :mime_type => nil})
        raise "File cannot be nil!" if opts[:file].nil?
        step = opts[:step]
        file = opts[:file]
        title = opts[:title] || File.basename(file)
        LOGGER.debug  "Adding attachment #{opts[:title]} to #{suite}.#{test}#{step.nil? ? "" : ".#{step[:title]}"}"
        dir = Pathname.new(Dir.pwd).join(config.output_dir)
        FileUtils.mkdir_p(dir)
        file_extname = File.extname(file.path.downcase)
        mime_type = opts[:mime_type] || MimeMagic.by_path(file.path) || "text/plain"
        attachment = dir.join("#{Digest::SHA256.file(file.path).hexdigest}-attachment#{(file_extname.empty?) ? '' : file_extname}")
        LOGGER.debug "Copying attachment to '#{attachment}'..."
        FileUtils.cp(file.path, attachment)
        attach = {
            :type => mime_type,
            :title => title,
            :source => attachment.basename,
            :file => attachment.basename,
            :target => attachment.basename,
            :size => File.stat(attachment).size
        }
        if step.nil?
          self.suites[suite][:tests][test][:attachments] << attach
        else
          self.suites[suite][:tests][test][:steps][step[:index]][:attachments] << attach
        end
      end

      def build!(opts = {}, &block)
        suites_xml = []
        (self.suites || []).each do |suite_title, suite|
          builder = Nokogiri::XML::Builder.new do |xml|
            xml.send "ns2:test-suite", :start => suite[:start] || 0, :stop => suite[:stop] || 0, 'xmlns' => '', "xmlns:ns2" => "urn:model.allure.qatools.yandex.ru" do
              xml.send :name, suite_title
              xml.send :title, suite_title
              xml.send "test-cases" do
                suite[:tests].each do |test_title, test|
                  xml.send "test-case", :start => test[:start] || 0, :stop => test[:stop] || 0, :status => test[:status] do
                    xml.send :name, test_title
                    xml.send :title, test_title
                    unless test[:failure].nil?
                      xml.failure do
                        xml.message test[:failure][:message]
                        xml.send "stack-trace", test[:failure][:stacktrace]
                      end
                    end
                    xml.steps do
                      test[:steps].each do |step|
                        xml.step(:start => step[:start] || 0, :stop => step[:stop] || 0, :status => step[:status]) do
                          xml.send :name, step[:title]
                          xml.send :title, step[:title]
                          xml_attachments(xml, step[:attachments])
                        end
                      end
                    end
                    xml_attachments(xml, test[:attachments])
                    xml_labels(xml, suite[:labels].merge(test[:labels]))
                    xml.parameters
                  end
                end
              end
              xml_labels(xml, suite[:labels])
            end
          end
          unless suite[:tests].empty?
            xml = builder.to_xml
            xml = yield suite, xml if block_given?
            dir = Pathname.new(config.output_dir)
            FileUtils.mkdir_p(dir)
            out_file = dir.join("#{UUID.new.generate}-testsuite.xml")
            LOGGER.debug "Writing file '#{out_file}'..."
            File.open(out_file, 'w+') do |file|
              file.write(validate_xml(xml))
            end
            suites_xml << xml
          end
        end
        suites_xml
      end

      private

      def add_default_labels(labels = {})
        labels[:thread] ||= Thread.current.object_id
        labels[:host] ||= HOSTNAME
        labels
      end

      def config
        AllureRubyAdaptorApi::Config
      end

      def init_suites
        MUTEX.synchronize {
          self.suites ||= {}
        }
        LOGGER.level = config.logging_level
      end

      def timestamp(time = nil)
        ((time || Time.now).to_f * 1000).to_i
      end

      def validate_xml(xml)
        xsd = Nokogiri::XML::Schema(File.read(Pathname.new(File.dirname(__FILE__)).join("../../allure-model-#{AllureRubyAdaptorApi::Version::ALLURE}.xsd")))
        doc = Nokogiri::XML(xml)

        xsd.validate(doc).each do |error|
          $stderr.puts error.message
        end
        xml
      end


      def xml_attachments(xml, attachments)
        xml.attachments do
          attachments.each do |attach|
            xml.attachment :source => attach[:source], :title => attach[:title], :size => attach[:size], :type => attach[:type]
          end
        end
      end

      def xml_labels(xml, labels)
        xml.labels do
          labels.each do |name, value|
            if value.is_a?(Array)
              value.each do |v|
                xml.label :name => name, :value => v
              end
            else
              xml.label :name => name, :value => value
            end
          end
        end
      end
    end
  end
end
