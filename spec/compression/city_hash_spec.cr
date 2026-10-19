require "spec"
require "../../src/clickhouse/compression/city_hash"

describe ClickHouse::Compression::CityHash do
  it "matches pinned upstream CityHash 1.0.2 C++ vectors across all length branches" do
    vectors = [
      {0, 0x3df09dfc64c09a2b_u64, 0x3cb540c392e51e29_u64},
      {1, 0x68c4d90df5a5eb8f_u64, 0xbe4ed390c455dce6_u64},
      {4, 0xb4eed170950330f7_u64, 0x4f84a44a9e8d5b89_u64},
      {7, 0x61143721a76fca6b_u64, 0x77a34566a7f31f27_u64},
      {8, 0xc2e4f458b3b7a090_u64, 0x9f28b016667abb69_u64},
      {9, 0x9ed250ac70ca0390_u64, 0xa73eac5e3a68a659_u64},
      {15, 0xd4d6751e5483a5e4_u64, 0xf8564cb39abc8640_u64},
      {16, 0xa080a19e515664d2_u64, 0xab230625b26fb61d_u64},
      {17, 0x92b012730a3b6b89_u64, 0x69ade1384ca751ed_u64},
      {31, 0x88ab07acf1fc3ed3_u64, 0xee36b79d6bf27ac3_u64},
      {32, 0xc10a0d477b4dd0bb_u64, 0xe046a7b927b7c58a_u64},
      {64, 0x5eeaf493f0d03528_u64, 0x73c01bf8c202848d_u64},
      {127, 0x7cf86245f903cde8_u64, 0x727b0927f7f85a17_u64},
      {128, 0xbf72745b132de5c5_u64, 0xb48a4e3a9ff0fade_u64},
      {129, 0xd090fe57e8f8a9f8_u64, 0xbc90c5a34f9688f2_u64},
      {143, 0x052b1d7cabaffa2b_u64, 0xce3f475f7b6c76b7_u64},
      {144, 0x15c0fe45b85cb416_u64, 0x7ceaf3c65dadd43b_u64},
      {145, 0xf832d574d3925ea8_u64, 0x813b8340bcc72326_u64},
      {255, 0x49e348a47192eaf6_u64, 0x4ad86d5a94c9a6b5_u64},
      {256, 0x40a9921b0883ce7d_u64, 0x023ad0478d6c60a2_u64},
      {1024, 0x9ee637872fa573e7_u64, 0x60572d1c3d09f825_u64},
      {65537, 0x5f716e55538de5ee_u64, 0xadb32594f82141c3_u64},
    ]
    vectors.each do |size, low, high|
      input = Bytes.new(size) { |index| ((index * 37 + 11) & 255).to_u8 }
      ClickHouse::Compression::CityHash.hash128(input).should eq({low, high})
    end
  end
end
