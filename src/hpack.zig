
const std = @import("std");
const huffman = @import("huffman.zig");

fn huffmanLength(str :[]u8) usize {
    var len :usize= 0;
    for (str) |c| {
        len += huffman.codes[c].bits;
    }
    return (len + 7) / 8;
}

pub fn encodeInteger(w :std.io.AnyWriter, comptime prefix_len :u32,comptime prefix :u8,value :u64) anyerror!void {
   if(prefix_len >= 8) {
        @compileError("prefix_len must be less than 8");
   }
   const mask = !u8(0) >> (8 - prefix_len); 
   if(mask & prefix != 0) {
        @compileError("prefix must be less than or equal to 2^prefix_len - 1");
   }
   if(value < u64(mask)) {
      try w.writeByte(prefix | u8(value));
   }
   else {
        try w.writeByte(prefix | mask);
        value -= u64(mask);
        while(value >= 128) {
             try w.writeByte(u8(value & 0x7F) | 0x80);
             value >>= 7;
        }
        try w.writeByte(u8(value));
    }
}

pub fn decodeInteger(r :std.io.AnyReader, comptime prefix_len :u32,prefix :*u8) anyerror!u64 {
    if(prefix_len >= 8) {
        @compileError("prefix_len must be less than 8");
    }
    const mask = !u8(0) >> (8 - prefix_len); 
    var b = try r.readByte();
    if (prefix != null) {
        prefix.* = b & !mask;
    }
    var value = u64(b & mask);
    if (value < u64(mask)) {
        return value;
    }
    var shift = 0;
    while(b & 0x80 != 0) {
        b = try r.readByte();
        value |= u64(b & 0x7F) << shift;
        shift += 7;
        if (shift > 64) {
            return error.OutOfRange;
        }
    }
    value |= u64(b) << shift;
    return value;
}

fn encodeString(w :std.io.AnyWriter,comptime prefix :u8,str :[]u8) anyerror!void {
    const len = huffmanLength(str);
    if (len > str.len) {
        try encodeInteger(w, 7, !0x80|prefix, u64(str.len));
        try w.writeAll(str);
    }
    else {
        try encodeInteger(w, 7, 0x80|prefix, u64(len));
        const bitWriter = huffman.BitWriter.init(w);
        for (str) |c| {
            try huffman.codes[c].write(bitWriter);
        }
        while (bitWriter.bit_count % 8 != 0) {
            try bitWriter.write(1);
        }
    }
}


fn decodeSingleChar(r :huffman.BitReader,allone :*u32) anyerror!huffman.HuffmanTree {
    var node = huffman.getRoot();
    while(true) {
        if(node.has_value()) {
            return node;
        }
        const bit = try r.readBitsNoEof(u1,1);
        allone.* = if ((allone.* != 0) and (bit != 0)) allone.* + 1 else 0;
        node = try huffman.get_next(node, bit);
    }
}

pub const U8Array = std.ArrayList(u8);

fn decodeHuffmanString(alloc :std.mem.Allocator, r :std.io.AnyReader) anyerror!U8Array {
    const bitReader = huffman.BitReader.init(r);
    var result = U8Array.init(alloc);
    while(true) {
        var allone :u32 = 0;
        const node = decodeSingleChar(bitReader, &allone);
        if(node) |n| {
            if(n.get_value() == 256) {
                return error.OutOfRange;
            }
            try result.append(@intCast( n.get_value()));
        } else |x| {
            if((x == error.EndOfStream) and (allone - 1 <= 7)) {
                break;
            }
            return x;
        }
    }
    return result;
}

pub fn decodeString(alloc :std.mem.Allocator, r :std.io.AnyReader) anyerror!U8Array {
    var prefix :u8 = 0;
    const len =try decodeInteger(r, 7, &prefix);
    const str = [len]u8{}; 
    try r.readNoEof(str);
    if(prefix & 0x80 != 0) {
        const s = std.io.fixedBufferStream(str);
        return decodeHuffmanString(alloc, s);
    }
    else {
        const ret = U8Array.init(alloc);
        ret.appendSlice(str);
        return ret;
    }
}

const KeyValue = struct {
    key :[]const u8,
    value :[]const u8,
};

const predefinedHeaders = [_]KeyValue{
KeyValue{.key = "INVALIDINDEX", .value = "INVALIDINDEX"},
KeyValue{.key = ":authority", .value = ""},
KeyValue{.key = ":method", .value = "GET"},
KeyValue{.key = ":method", .value = "POST"},
KeyValue{.key = ":path", .value = "/"},
KeyValue{.key = ":path", .value = "/index.html"},
KeyValue{.key = ":scheme", .value = "http"},
KeyValue{.key = ":scheme", .value = "https"},
KeyValue{.key = ":status", .value = "200"},
KeyValue{.key = ":status", .value = "204"},
KeyValue{.key = ":status", .value = "206"},
KeyValue{.key = ":status", .value = "304"},
KeyValue{.key = ":status", .value = "400"},
KeyValue{.key = ":status", .value = "404"},
KeyValue{.key = ":status", .value = "500"},
KeyValue{.key = "accept-charset", .value = ""},
KeyValue{.key = "accept-encoding", .value = "gzip, deflate"},
KeyValue{.key = "accept-language", .value = ""},
KeyValue{.key = "accept-ranges", .value = ""},
KeyValue{.key = "accept", .value = ""},
KeyValue{.key = "access-control-allow-origin", .value = ""},
KeyValue{.key = "age", .value = ""},
KeyValue{.key = "allow", .value = ""},
KeyValue{.key = "authorization", .value = ""},
KeyValue{.key = "cache-control", .value = ""},
KeyValue{.key = "content-disposition", .value = ""},
KeyValue{.key = "content-encoding", .value = ""},
KeyValue{.key = "content-language", .value = ""},
KeyValue{.key = "content-length", .value = ""},
KeyValue{.key = "content-location", .value = ""},
KeyValue{.key = "content-range", .value = ""},
KeyValue{.key = "content-type", .value = ""},
KeyValue{.key = "cookie", .value = ""},
KeyValue{.key = "date", .value = ""},
KeyValue{.key = "etag", .value = ""},
KeyValue{.key = "expect", .value = ""},
KeyValue{.key = "expires", .value = ""},
KeyValue{.key = "from", .value = ""},
KeyValue{.key = "host", .value = ""},
KeyValue{.key = "if-match", .value = ""},
KeyValue{.key = "if-modified-since", .value = ""},
KeyValue{.key = "if-none-match", .value = ""},
KeyValue{.key = "if-range", .value = ""},
KeyValue{.key = "if-unmodified-since", .value = ""},
KeyValue{.key = "last-modified", .value = ""},
KeyValue{.key = "link", .value = ""},
KeyValue{.key = "location", .value = ""},
KeyValue{.key = "max-forwards", .value = ""},
KeyValue{.key = "proxy-authenticate", .value = ""},
KeyValue{.key = "proxy-authorization", .value = ""},
KeyValue{.key = "range", .value = ""},
KeyValue{.key = "referer", .value = ""},
KeyValue{.key = "refresh", .value = ""},
KeyValue{.key = "retry-after", .value = ""},
KeyValue{.key = "server", .value = ""},
KeyValue{.key = "set-cookie", .value = ""},
KeyValue{.key = "strict-transport-security", .value = ""},
KeyValue{.key = "transfer-encoding", .value = ""},
KeyValue{.key = "user-agent", .value = ""},
KeyValue{.key = "vary", .value = ""},
KeyValue{.key = "via", .value = ""},
KeyValue{.key = "www-authenticate", .value = ""},

};

const KeyValEntry = struct {
    keyvalue :KeyValue,
    index :u32,
};

fn getTableEntry(key :[]const u8, value :[]const u8,hdr_equal :bool) ?KeyValEntry {
    for(predefinedHeaders,0..) |entry,i| {
        if(hdr_equal) {
            if(entry.key == key) {
                return KeyValEntry{.keyvalue = entry, .index = i};
            }
        }
        else {
            if(entry.key == key and entry.value == value) {
                return KeyValEntry{.keyvalue = entry, .index = i};
            }
        }
    }
    return null;
}