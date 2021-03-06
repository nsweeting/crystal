require "c/sys/mman"

# :nodoc:
@[NoInline]
fun _fiber_get_stack_top : Void*
  dummy = uninitialized Int32
  pointerof(dummy).as(Void*)
end

class Fiber
  STACK_SIZE = 8 * 1024 * 1024

  @@first_fiber : Fiber? = nil
  @@last_fiber : Fiber? = nil
  @@stack_pool = [] of Void*

  @stack : Void*
  @resume_event : Event::Event?
  @stack_top = uninitialized Void*
  protected property stack_top : Void*
  protected property stack_bottom : Void*
  protected property next_fiber : Fiber?
  protected property prev_fiber : Fiber?
  property name : String?

  def initialize(@name : String? = nil, &@proc : ->)
    @stack = Fiber.allocate_stack
    @stack_bottom = @stack + STACK_SIZE
    fiber_main = ->(f : Fiber) { f.run }

    stack_ptr = @stack + STACK_SIZE - sizeof(Void*)

    # Align the stack pointer to 16 bytes
    stack_ptr = Pointer(Void*).new(stack_ptr.address & ~0x0f_u64)

    # @stack_top will be the stack pointer on the initial call to `resume`
    {% if flag?(:x86_64) %}
      # In x86-64, the context switch push/pop 7 registers
      @stack_top = (stack_ptr - 7).as(Void*)

      stack_ptr[0] = fiber_main.pointer # Initial `resume` will `ret` to this address
      stack_ptr[-1] = self.as(Void*)    # This will be `pop` into %rdi (first argument)
    {% elsif flag?(:i686) %}
      # In IA32, the context switch push/pops 4 registers.
      # Add two more to store the argument of `fiber_main`
      @stack_top = (stack_ptr - 6).as(Void*)

      stack_ptr[0] = self.as(Void*)      # First argument passed on the stack
      stack_ptr[-1] = Pointer(Void).null # Empty space to keep the stack alignment (16 bytes)
      stack_ptr[-2] = fiber_main.pointer # Initial `resume` will `ret` to this address
    {% else %}
      {{ raise "Unsupported platform, only x86_64 and i686 are supported." }}
    {% end %}

    @prev_fiber = nil
    if last_fiber = @@last_fiber
      @prev_fiber = last_fiber
      last_fiber.next_fiber = @@last_fiber = self
    else
      @@first_fiber = @@last_fiber = self
    end
  end

  def initialize
    @proc = Proc(Void).new { }
    @stack = Pointer(Void).null
    @stack_top = _fiber_get_stack_top
    @stack_bottom = LibGC.stackbottom
    @name = "main"

    @@first_fiber = @@last_fiber = self
  end

  protected def self.allocate_stack
    @@stack_pool.pop? || LibC.mmap(nil, Fiber::STACK_SIZE,
      LibC::PROT_READ | LibC::PROT_WRITE,
      LibC::MAP_PRIVATE | LibC::MAP_ANON,
      -1, 0).tap do |pointer|
      raise Errno.new("Cannot allocate new fiber stack") if pointer == LibC::MAP_FAILED
      {% if flag?(:linux) %}
        LibC.madvise(pointer, Fiber::STACK_SIZE, LibC::MADV_NOHUGEPAGE)
      {% end %}
      LibC.mprotect(pointer, 4096, LibC::PROT_NONE)
    end
  end

  def self.stack_pool_collect
    return if @@stack_pool.size == 0
    free_count = @@stack_pool.size > 1 ? @@stack_pool.size / 2 : 1
    free_count.times do
      stack = @@stack_pool.pop
      LibC.munmap(stack, Fiber::STACK_SIZE)
    end
  end

  def run
    @proc.call
  rescue ex
    if name = @name
      STDERR.puts "Unhandled exception in spawn(name: #{name}):"
    else
      STDERR.puts "Unhandled exception in spawn:"
    end
    ex.inspect_with_backtrace STDERR
    STDERR.flush
  ensure
    @@stack_pool << @stack

    # Remove the current fiber from the linked list
    if prev_fiber = @prev_fiber
      prev_fiber.next_fiber = @next_fiber
    else
      @@first_fiber = @next_fiber
    end

    if next_fiber = @next_fiber
      next_fiber.prev_fiber = @prev_fiber
    else
      @@last_fiber = @prev_fiber
    end

    # Delete the resume event if it was used by `yield` or `sleep`
    @resume_event.try &.free

    Scheduler.reschedule
  end

  @[NoInline]
  @[Naked]
  protected def self.switch_stacks(current, to)
    # TODO: these \% escapes are needed because of https://github.com/crystal-lang/crystal/issues/2178
    # Remove them once that issue is fixed.
    {% if flag?(:x86_64) %}
      asm("
        pushq \%rdi
        pushq \%rbx
        pushq \%rbp
        pushq \%r12
        pushq \%r13
        pushq \%r14
        pushq \%r15
        movq \%rsp, ($0)
        movq ($1), \%rsp
        popq \%r15
        popq \%r14
        popq \%r13
        popq \%r12
        popq \%rbp
        popq \%rbx
        popq \%rdi"
              :: "r"(current), "r"(to))
    {% elsif flag?(:i686) %}
      asm("
        pushl \%edi
        pushl \%ebx
        pushl \%ebp
        pushl \%esi
        movl \%esp, ($0)
        movl ($1), \%esp
        popl \%esi
        popl \%ebp
        popl \%ebx
        popl \%edi"
              :: "r"(current), "r"(to))
    {% end %}
  end

  def resume
    current, Thread.current.current_fiber = Thread.current.current_fiber, self
    LibGC.stackbottom = @stack_bottom
    Fiber.switch_stacks(pointerof(current.@stack_top), pointerof(@stack_top))
  end

  def sleep(time)
    event = @resume_event ||= Scheduler.create_resume_event(self)
    event.add(time)
    Scheduler.reschedule
  end

  def yield
    sleep(0)
  end

  def self.sleep(time)
    Fiber.current.sleep(time)
  end

  def self.yield
    Fiber.current.yield
  end

  def to_s(io)
    io << "#<" << self.class.name << ":0x"
    object_id.to_s(16, io)
    if name = @name
      io << ": " << name
    end
    io << ">"
  end

  def inspect(io)
    to_s(io)
  end

  protected def push_gc_roots
    # Push the used section of the stack
    LibGC.push_all_eager @stack_top, @stack_bottom
  end

  @@root = new

  def self.root : self
    @@root
  end

  Thread.current.current_fiber = root

  def self.current : self
    Thread.current.current_fiber
  end

  @@prev_push_other_roots = LibGC.get_push_other_roots

  # This will push all fibers stacks whenever the GC wants to collect some memory
  LibGC.set_push_other_roots ->do
    @@prev_push_other_roots.call

    fiber = @@first_fiber
    while fiber
      fiber.push_gc_roots unless fiber == Thread.current.current_fiber
      fiber = fiber.next_fiber
    end
  end
end
