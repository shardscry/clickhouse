require "../errors"

class ClickHouse::Protocol::Deadline
  @stopped = Channel(Nil).new(1)
  @expired = Atomic(Bool).new(false)
  @ends_at : Time::Instant

  def initialize(@io : IO, duration : Time::Span)
    @ends_at = Time.instant + duration
    spawn do
      select
      when @stopped.receive
      when timeout(duration)
        @expired.set(true)
        @io.close rescue nil
      end
    end
  end

  def expired? : Bool
    @expired.get || Time.instant >= @ends_at
  end

  def stop : Nil
    @stopped.send(nil)
  end
end
