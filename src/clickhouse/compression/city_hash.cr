# CityHash 1.0.2, as required by the ClickHouse native protocol.
# Adapted from Google's implementation; see THIRD_PARTY_NOTICES.md.
module ClickHouse::Compression::CityHash
  extend self

  private K0 = 0xc3a5c85c97cb3127_u64
  private K1 = 0xb492b66fbe98f273_u64
  private K2 = 0x9ae16a3b2f90404f_u64
  private K3 = 0xc949d7c7509e6557_u64

  # Returns the low and high halves in ClickHouse's checksum order.
  def hash128(bytes : Bytes) : Tuple(UInt64, UInt64)
    size = bytes.size
    if size >= 16
      seeded(bytes, 16, size - 16, fetch64(bytes, 0) ^ K3, fetch64(bytes, 8))
    elsif size >= 8
      seeded(bytes, 0, 0, fetch64(bytes, 0) ^ (size.to_u64 &* K0), fetch64(bytes, size - 8) ^ K1)
    else
      seeded(bytes, 0, size, K0, K1)
    end
  end

  private def fetch64(bytes : Bytes, offset : Int32) : UInt64
    IO::ByteFormat::LittleEndian.decode(UInt64, bytes[offset, 8])
  end

  private def fetch32(bytes : Bytes, offset : Int32) : UInt64
    IO::ByteFormat::LittleEndian.decode(UInt32, bytes[offset, 4]).to_u64
  end

  private def rotate(value : UInt64, shift : Int32) : UInt64
    (value >> shift) | (value << (64 - shift))
  end

  private def mix(value : UInt64) : UInt64
    value ^ (value >> 47)
  end

  private def hash16(first : UInt64, second : UInt64) : UInt64
    multiplier = 0x9ddfea08eb382d69_u64
    first = (first ^ second) &* multiplier
    first ^= first >> 47
    second = (second ^ first) &* multiplier
    second ^= second >> 47
    second &* multiplier
  end

  private def short_hash(bytes : Bytes, offset : Int32, size : Int32) : UInt64
    if size > 8
      first = fetch64(bytes, offset)
      last = fetch64(bytes, offset + size - 8)
      hash16(first, rotate(last &+ size.to_u64, size)) ^ last
    elsif size >= 4
      first = fetch32(bytes, offset)
      hash16(size.to_u64 &+ (first << 3), fetch32(bytes, offset + size - 4))
    elsif size > 0
      first = bytes[offset].to_u64
      middle = bytes[offset + (size >> 1)].to_u64
      last = bytes[offset + size - 1].to_u64
      mixed = first &+ (middle << 8)
      tail = size.to_u64 &+ (last << 2)
      mix((mixed &* K2) ^ (tail &* K3)) &* K2
    else
      K2
    end
  end

  private def murmur(bytes : Bytes, offset : Int32, size : Int32, first : UInt64, second : UInt64) : Tuple(UInt64, UInt64)
    third = fourth = 0_u64
    remaining = size - 16
    if remaining <= 0
      first = mix(first &* K1) &* K1
      third = (second &* K1) &+ short_hash(bytes, offset, size)
      fourth = mix(first &+ (size >= 8 ? fetch64(bytes, offset) : third))
    else
      third = hash16(fetch64(bytes, offset + size - 8) &+ K1, first)
      fourth = hash16(second &+ size.to_u64, third &+ fetch64(bytes, offset + size - 16))
      first &+= fourth
      loop do
        first ^= mix(fetch64(bytes, offset) &* K1) &* K1
        first &*= K1
        second ^= first
        third ^= mix(fetch64(bytes, offset + 8) &* K1) &* K1
        third &*= K1
        fourth ^= third
        offset += 16
        remaining -= 16
        break if remaining <= 0
      end
    end
    first = hash16(first, third)
    second = hash16(fourth, second)
    {first ^ second, hash16(second, first)}
  end

  private def weak_hash(bytes : Bytes, offset : Int32, first : UInt64, second : UInt64) : Tuple(UInt64, UInt64)
    first &+= fetch64(bytes, offset)
    last = fetch64(bytes, offset + 24)
    second = rotate(second &+ first &+ last, 21)
    previous = first
    first &+= fetch64(bytes, offset + 8)
    first &+= fetch64(bytes, offset + 16)
    second &+= rotate(first, 44)
    {first &+ last, second &+ previous}
  end

  private def seeded(bytes : Bytes, offset : Int32, size : Int32, first : UInt64, second : UInt64) : Tuple(UInt64, UInt64)
    return murmur(bytes, offset, size, first, second) if size < 128

    third = size.to_u64 &* K1
    v_first = (rotate(second ^ K1, 49) &* K1) &+ fetch64(bytes, offset)
    v_second = (rotate(v_first, 42) &* K1) &+ fetch64(bytes, offset + 8)
    w_first = (rotate(second &+ third, 35) &* K1) &+ first
    w_second = rotate(first &+ fetch64(bytes, offset + 88), 53) &* K1

    while size >= 128
      2.times do
        first = rotate(first &+ second &+ v_first &+ fetch64(bytes, offset + 16), 37) &* K1
        second = rotate(second &+ v_second &+ fetch64(bytes, offset + 48), 42) &* K1
        first ^= w_second
        second ^= v_first
        third = rotate(third ^ w_first, 33)
        v_first, v_second = weak_hash(bytes, offset, v_second &* K1, first &+ w_first)
        w_first, w_second = weak_hash(bytes, offset + 32, third &+ w_second, second)
        first, third = third, first
        offset += 64
      end
      size -= 128
    end
    second &+= (rotate(w_first, 37) &* K0) &+ third
    first &+= rotate(v_first &+ third, 49) &* K0
    tail_done = 0
    while tail_done < size
      tail_done += 32
      tail = offset + size - tail_done
      second = (rotate(second &- first, 42) &* K0) &+ v_second
      w_first &+= fetch64(bytes, tail + 16)
      first = (rotate(first, 49) &* K0) &+ w_first
      w_first &+= v_first
      v_first, v_second = weak_hash(bytes, tail, v_first, v_second)
    end
    first = hash16(first, v_first)
    second = hash16(second, w_first)
    {hash16(first &+ v_second, w_second) &+ second, hash16(first &+ w_second, second &+ v_second)}
  end
end
