require "./version"

record ClickHouse::ServerInfo,
  name : String, major : Int32, minor : Int32, revision : Int32,
  timezone : String, display_name : String, patch : Int32
