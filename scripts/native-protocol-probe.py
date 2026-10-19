#!/usr/bin/env python3
"""Independent revision-54460 conformance probe; never used by the Crystal driver."""

import argparse
import hashlib
import json
import socket
import ssl
import struct
import uuid
from pathlib import Path

REVISION = 54460
SOURCE = "abf12b3b072bc93aadeb8c5d15f42fc20f9ee82a"
REFERENCE = "600546438865214b4f407cae06a9492c925b8802"
MAX_BYTES = 16 * 1024 * 1024
PACKETS = {
    0: "Hello", 1: "Data", 2: "Exception", 3: "Progress", 4: "Pong",
    5: "EndOfStream", 6: "ProfileInfo", 7: "Totals", 8: "Extremes",
    10: "Log", 11: "TableColumns", 14: "ProfileEvents",
}


def varuint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def string(value):
    if isinstance(value, str):
        value = value.encode()
    return varuint(len(value)) + value


def quoted(value):
    escapes = {"\\": "\\\\", "'": "\\'", "\x00": "\\0", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return "'" + "".join(escapes.get(char, char) for char in value) + "'"


def parameter_text(value):
    escapes = {"\\": "\\\\", "\x00": "\\0", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return "".join(escapes.get(char, char) for char in value)


class ServerError(Exception):
    def __init__(self, code, name, message):
        self.code = code
        super().__init__(f"{code} {name}: {message}")


class Probe:
    def __init__(self, options, password=None):
        self.options = options
        self.trace = []
        self.raw = bytearray()
        self.cancel_capture = False
        self.cancel_packets_discarded = {}
        self.connection = socket.create_connection((options.host, options.port), timeout=10)
        self.connection.settimeout(10)
        if options.tls:
            context = ssl.create_default_context(cafile=options.ca)
            self.connection = context.wrap_socket(self.connection, server_hostname=options.tls_hostname)
        self.reader = self.connection.makefile("rb", buffering=0)
        hello = b"\x00" + string("Crystal phase-0 independent Python probe")
        hello += varuint(0) + varuint(1) + varuint(REVISION)
        hello += string("default") + string("default") + string(password or options.password)
        self.send("ClientHello", hello)
        self.begin()
        code = self.uint()
        if code == 2:
            raise self.exception()
        assert code == 0, code
        self.server = {"name": self.text(), "major": self.uint(), "minor": self.uint(), "revision": self.uint()}
        self.server.update(timezone=self.text(), display_name=self.text(), patch=self.uint())
        assert self.server["revision"] >= REVISION
        self.record("ServerHello")
        self.send("Addendum (no packet code)", string(""))

    def close(self):
        self.reader.close()
        self.connection.close()

    def send(self, name, data):
        self.connection.sendall(data)
        self.trace.append({"direction": "client", "packet": name, "hex": data.hex()})
        if name == "Cancel":
            self.cancel_capture = True

    def begin(self):
        self.raw.clear()

    def record(self, name):
        if self.cancel_capture and name not in ("EndOfStream", "Exception"):
            self.cancel_packets_discarded[name] = self.cancel_packets_discarded.get(name, 0) + 1
            return
        packet = {"direction": "server", "packet": name}
        if name in ("ProfileEvents", "Progress", "ProfileInfo"):
            packet.update(bytes=len(self.raw), sha256=hashlib.sha256(self.raw).hexdigest())
        else:
            packet["hex"] = self.raw.hex()
        self.trace.append(packet)

    def read(self, count):
        assert 0 <= count <= MAX_BYTES, count
        result = bytearray()
        while len(result) < count:
            chunk = self.reader.read(count - len(result))
            if not chunk:
                raise EOFError("Peer closed in a packet")
            result.extend(chunk)
        self.raw.extend(result)
        return bytes(result)

    def uint(self):
        result = 0
        for shift in range(0, 70, 7):
            byte = self.read(1)[0]
            if shift == 63 and byte > 1:
                raise ValueError("VarUInt overflow")
            result |= (byte & 127) << shift
            if byte < 128:
                return result
        raise ValueError("Unterminated VarUInt")

    def bytes(self):
        return self.read(self.uint())

    def text(self):
        return self.bytes().decode()

    def exception(self):
        code = struct.unpack("<i", self.read(4))[0]
        name, message = self.text(), self.text()
        self.text()
        if self.read(1) != b"\x00":
            self.exception()
        return ServerError(code, name, message)

    def block(self):
        while True:
            field = self.uint()
            if field == 0:
                break
            if field == 1:
                self.read(1)
            elif field == 2:
                self.read(4)
            else:
                raise ValueError(f"Unknown BlockInfo field {field}")
        columns, rows = self.uint(), self.uint()
        assert columns <= 256 and rows <= 100000, (columns, rows)
        names, types, values = [], [], []
        for _ in range(columns):
            names.append(self.text())
            kind = self.text()
            types.append(kind)
            assert self.read(1) == b"\x00", "Non-default serialization"
            values.append(self.column(kind, rows))
        return {"names": names, "types": types, "rows": list(map(list, zip(*values)))}

    def column(self, kind, rows):
        numeric = {"UInt8": "B", "UInt16": "H", "UInt32": "I", "UInt64": "Q",
                   "Int8": "b", "Int16": "h", "Int32": "i", "Int64": "q",
                   "Float32": "f", "Float64": "d", "DateTime": "I", "Date": "H"}
        if kind in numeric:
            code = numeric[kind]
            return list(struct.unpack("<" + code * rows, self.read(struct.calcsize(code) * rows)))
        if kind == "String":
            return [self.bytes().decode() for _ in range(rows)]
        if kind.startswith("DateTime("):
            return self.column("DateTime", rows)
        if kind.startswith("Enum8("):
            return self.column("Int8", rows)
        if kind.startswith("Enum16("):
            return self.column("Int16", rows)
        raise ValueError(f"Probe does not implement {kind}")

    def packet(self):
        self.begin()
        code = self.uint()
        result = None
        if code in (1, 7, 8, 10, 14):
            self.text()
            result = self.block()
        elif code == 2:
            result = self.exception()
        elif code == 3:
            result = [self.uint() for _ in range(6)]
        elif code == 6:
            result = [self.uint() for _ in range(3)]
            result += [self.read(1).hex(), self.uint(), self.read(1).hex()]
        elif code == 11:
            result = [self.text(), self.text()]
        elif code not in (4, 5):
            raise ValueError(f"Unexpected packet {code}")
        self.record(PACKETS[code])
        return code, result

    def query_packet(self, sql, params=None, settings=None):
        self.cancel_capture = False
        query_id = str(uuid.uuid4())
        info = b"\x01" + string("") + string(query_id) + string("127.0.0.1:0")
        info += struct.pack("<q", 0) + b"\x01" + string("") + string("") + string("Crystal phase-0 probe")
        info += varuint(0) + varuint(1) + varuint(REVISION)
        info += string("") + varuint(0) + varuint(0) + b"\x00" + b"\x00\x00\x00"
        packet = b"\x01" + string(query_id) + info
        for key, value in (settings or {}).items():
            packet += string(key) + varuint(0) + string(str(value))
        packet += string("") + string("") + varuint(2) + varuint(0) + string(sql)
        for key, value in (params or {}).items():
            packet += string(key) + varuint(2) + string(quoted(parameter_text(value)))
        packet += string("")
        self.send("Query", packet)

    def data(self, names=(), types=(), rows=(), label="Data"):
        packet = b"\x02" + string("") + b"\x01\x00\x02\xff\xff\xff\xff\x00"
        packet += varuint(len(names)) + varuint(len(rows))
        for index, (name, kind) in enumerate(zip(names, types)):
            packet += string(name) + string(kind) + b"\x00"
            for row in rows:
                packet += struct.pack("<Q", row[index]) if kind == "UInt64" else string(row[index])
        self.send(label, packet)

    def drain(self):
        result = []
        while True:
            code, body = self.packet()
            if code == 2:
                raise body
            if code == 5:
                return result
            if code == 1:
                result.extend(body["rows"])

    def query(self, sql, **options):
        self.query_packet(sql, **options)
        self.data(label="Data (external-table EOF)")
        return self.drain()

    def insert(self, table, rows):
        self.query_packet(f"INSERT INTO {table} (id, name) VALUES")
        self.data(label="Data (external-table EOF)")
        while True:
            code, schema = self.packet()
            if code == 2:
                raise schema
            if code == 1:
                break
        assert schema["names"] == ["id", "name"] and schema["types"] == ["UInt64", "String"]
        self.data(schema["names"], schema["types"], rows)
        self.data(label="Data (insert-row EOF)")
        return self.drain()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=19000)
    parser.add_argument("--password", default="clickhouse_test")
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--ca")
    parser.add_argument("--tls-hostname", default="localhost")
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()
    checks = []
    client = Probe(options)
    table = "crystal_phase0_" + uuid.uuid4().hex
    try:
        client.send("Ping", b"\x04")
        assert client.packet()[0] == 4
        checks.append("Hello revision54460, addendum, Ping/Pong")
        client.server["version"] = client.query("SELECT version()")[0][0]
        assert client.query("SELECT toUInt64(42) AS answer, 'Ada' AS name") == [[42, "Ada"]]
        checks.append("SELECT schema, primitive rows, metadata and EndOfStream")
        assert client.query("SELECT number FROM numbers(10)", settings={"max_block_size": 2, "max_threads": 1}) == [[i] for i in range(10)]
        checks.append("multiple SELECT blocks")
        value = "Ada's \\path\nline\t\x00Ω"
        assert client.query("SELECT {id:UInt64}, {name:String}", params={"id": "42", "name": value}) == [[42, value]]
        checks.append("typed parameters with apostrophe, backslash, controls and Unicode")
        client.query(f"CREATE TABLE {table} (id UInt64, name String) ENGINE=Memory")
        client.insert(table, [[1, "Ada"], [2, "Grace"]])
        assert client.query(f"SELECT id, name FROM {table} ORDER BY id") == [[1, "Ada"], [2, "Grace"]]
        checks.append("INSERT external-table EOF, schema, rows, row EOF, read-back")
        try:
            client.query("SELECT * FROM crystal_phase0_table_that_does_not_exist")
        except ServerError as error:
            assert error.code == 60, error
        else:
            raise AssertionError("Missing query exception")
        assert client.query("SELECT toUInt64(7)") == [[7]]
        checks.append("Exception is terminal and next query remains synchronized")
        client.query_packet("SELECT number FROM numbers(1000000000)", settings={"max_block_size": 2, "max_threads": 1})
        client.data(label="Data (external-table EOF)")
        while client.packet()[0] != 1:
            pass
        client.send("Cancel", b"\x03")
        client.drain()
        assert client.query("SELECT toUInt64(9)") == [[9]]
        checks.append("Cancel/drain terminates and restores connection")
    finally:
        client.close()
        cleanup = Probe(options)
        try:
            cleanup.query(f"DROP TABLE IF EXISTS {table}")
        finally:
            cleanup.close()
    try:
        unauthorized = Probe(options, password="definitely-not-the-test-password")
    except ServerError as error:
        assert error.code == 516, error
        checks.append("authentication failure")
    else:
        unauthorized.close()
        raise AssertionError("Wrong password accepted")
    trace_bytes = json.dumps(client.trace, sort_keys=True).encode()
    report = {"generator": "scripts/native-protocol-probe.py", "client_revision": REVISION,
              "server_source": SOURCE, "reference_client_source": REFERENCE,
              "server": client.server, "tls_verified": options.tls,
              "checks": checks, "cancel_packets_discarded": client.cancel_packets_discarded,
              "trace_sha256": hashlib.sha256(trace_bytes).hexdigest(), "trace": client.trace}
    if options.output:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "trace"}, indent=2))


if __name__ == "__main__":
    main()
