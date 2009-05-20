require 'ticgit'
require 'ticgit/command'

# used Cap as a model for this - thanks Jamis

module TicGit
  class CLI
    def self.execute
      parse(ARGV).execute!
    end

    def self.parse(args)
      cli = new(args)
      cli.parse_options!
      cli
    end

    attr_reader :action, :options, :args, :tic
    attr_accessor :out

    def initialize(args, path = '.', out = $stdout)
      @args = args.dup
      @tic = TicGit.open(path, :keep_state => true)
      @options = OpenStruct.new
      @out = out

      @out.sync = true # so that Net::SSH prompts show up
    rescue NoRepoFound
      puts "No repo found"
      exit
    end

    def execute!
      if mod = Command.get(action)
        extend(mod)

        if respond_to?(:parser)
          option_parser = Command.parser(action, &method(:parser))
        else
          option_parser = Command.parser(action)
        end

        option_parser.parse!(args)

        execute if respond_to?(:execute)
      else
        puts usage

        if args.empty? and !action
          exit
        else
          puts('%p is not a command' % action)
          exit 1
        end
      end
    end

    def parse_options! #:nodoc:
      if args.empty?
        warn "Please specify at least one action to execute."
        puts
        puts usage(args)
        exit 1
      end

      @action = args.shift
    end

    def usage(args = nil)
      old_args = args || [action, *self.args].compact

      if respond_to?(:parser)
        Command.parser('COMMAND', &method(:parser))
        # option_parser.parse!(args)
      else
        Command.usage(old_args.first, old_args)
      end
    end

    def get_editor_message(message_file = nil)
      message_file = Tempfile.new('ticgit_message').path if !message_file

      editor = ENV["EDITOR"] || 'vim'
      system("#{editor} #{message_file}");
      message = File.readlines(message_file)
      message = message.select { |line| line[0, 1] != '#' } # removing comments
      if message.empty?
        return false
      else
        return message
      end
    end

    def ticket_show(t)
      days_ago = ((Time.now - t.opened) / (60 * 60 * 24)).round.to_s
      puts
      puts just('Title', 10) + ': ' + t.title
      puts just('TicId', 10) + ': ' + t.ticket_id
      puts
      puts just('Assigned', 10) + ': ' + t.assigned.to_s
      puts just('Opened', 10) + ': ' + t.opened.to_s + ' (' + days_ago + ' days)'
      puts just('State', 10) + ': ' + t.state.upcase
      if t.points == nil
        puts just('Points', 10) + ': no estimate'
      else
        puts just('Points', 10) + ': ' + t.points.to_s
      end
      if !t.tags.empty?
        puts just('Tags', 10) + ': ' + t.tags.join(', ')
      end
      puts
      if !t.comments.empty?
        puts 'Comments (' + t.comments.size.to_s + '):'
        t.comments.reverse.each do |c|
          puts '  * Added ' + c.added.strftime("%m/%d %H:%M") + ' by ' + c.user

          wrapped = c.comment.split("\n").collect do |line|
            line.length > 80 ? line.gsub(/(.{1,80})(\s+|$)/, "\\1\n").strip : line
          end * "\n"

          wrapped = wrapped.split("\n").map { |line| "\t" + line }
          if wrapped.size > 6
            puts wrapped[0, 6].join("\n")
            puts "\t** more... **"
          else
            puts wrapped.join("\n")
          end
          puts
        end
      end
    end

    class << self
      attr_accessor :window_lines, :window_cols

      TIOCGWINSZ_INTEL = 0x5413     # For an Intel processor
      TIOCGWINSZ_PPC   = 0x40087468 # For a PowerPC processor
      STDOUT_HANDLE    = 0xFFFFFFF5 # For windows

      def reset_window_width
        try_using(TIOCGWINSZ_PPC) ||
        try_using(TIOCGWINSZ_INTEL) ||
          try_windows ||
          use_fallback
      end

      # Set terminal dimensions using ioctl syscall on *nix platform
      # TODO: find out what is raised here on windows.
      def try_using(mask)
        buf = [0,0,0,0].pack("S*")

        if $stdout.ioctl(mask, buf) >= 0
          self.window_lines, self.window_cols = buf.unpack("S2")
          true
        end
      rescue Errno::EINVAL
      end

      def try_windows
        lines, cols = windows_terminal_size
        self.window_lines, self.window_cols = lines, cols if lines and cols
      end

      # Determine terminal dimensions on windows platform
      def windows_terminal_size
        m_GetStdHandle = Win32API.new(
          'kernel32', 'GetStdHandle', ['L'], 'L')
        m_GetConsoleScreenBufferInfo = Win32API.new(
          'kernel32', 'GetConsoleScreenBufferInfo', ['L', 'P'], 'L' )
        format = 'SSSSSssssSS'
        buf = ([0] * format.size).pack(format)
        stdout_handle = m_GetStdHandle.call(STDOUT_HANDLE)

        m_GetConsoleScreenBufferInfo.call(stdout_handle, buf)
        (bufx, bufy, curx, cury, wattr,
         left, top, right, bottom, maxx, maxy) = buf.unpack(format)
        return bottom - top + 1, right - left + 1
      end

      def use_fallback
        self.window_lines, self.window_cols = 25, 80
      end
    end

    def window_lines
      TicGit::CLI.window_lines
    end

    def window_cols
      TicGit::CLI.window_cols
    end

    if ''.respond_to?(:chars)
      # assume 1.9
      def just(value, size, side = :left)
        value = value.to_s

        if value.bytesize > size
          sub_value = "#{value[0, size - 1]}\xe2\x80\xa6"
        else
          sub_value = value[0, size]
        end

        just_common(sub_value, size, side)
      end
    else
      def just(value, size, side = :left)
        chars = value.to_s.scan(/./um)

        if chars.size > size
          sub_value = "#{chars[0, size-1]}\xe2\x80\xa6"
        else
          sub_value = chars.join
        end

        just_common(sub_value, size, side)
      end
    end

    def just_common(value, size, side)
      case side
      when :r, :right
        value.rjust(size)
      when :l, :left
        value.ljust(size)
      end
    end

    def puts(*strings)
      strings.each{|string| @out.puts(string) }
    end
  end
end

TicGit::CLI.reset_window_width
Signal.trap("SIGWINCH") { TicGit::CLI.reset_window_width }
