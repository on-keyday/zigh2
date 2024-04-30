
const std = @import("std");
const huffman = @import("huffman.zig");

fn huffmanLength(str :[]const u8) usize {
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
   const mask :u8 = ~(@as(u8,0)) >> (8 - prefix_len); 
   if(mask & prefix != 0) {
        @compileError("prefix must not overlap with mask");
   }
   if(value < @as(u64,mask)) {
      const v :u8 = @intCast(value);
      try w.writeByte(prefix | v);
   }
   else {
        try w.writeByte(prefix | mask);
        var val :u64 = value;
        val -= @intCast(mask);
        while(val >= 128) {
             const t :u8 = @intCast(val & 0x7F);
             try w.writeByte(t | 0x80);
             val >>= 7;
        }
        const t :u8 = @intCast(val);
        try w.writeByte(t);
    }
}

pub fn decodeIntegerWithFirstByte(r :std.io.AnyReader,comptime prefix_len :u32, first_byte :u8, prefix :?*u8) anyerror!u64 {
      if(prefix_len >= 8) {
        @compileError("prefix_len must be less than 8");
    }
    var b = first_byte;
    const mask = ~@as(u8,0) >> (8 - prefix_len); 
    if (prefix) |p|{
        p.* = b & ~mask;
    }
    var value :u64 = @intCast(b & mask);
    if (value < @as(u64,mask)) {
        return value;
    }
    var shift :u7= 0;
    while(true) {
        if (shift >= 64) {
            return error.OutOfRange;
        }
        b = try r.readByte();
        const s :u6 = @intCast(shift);
        value |= @as(u64,b & 0x7F) << s;
        if (b & 0x80 == 0) {
            break;
        }
        shift += 7;
    }
    return value;
}

pub fn decodeInteger(r :std.io.AnyReader, comptime prefix_len :u32,prefix :*u8) anyerror!u64 {
    const b = try r.readByte();
    return decodeIntegerWithFirstByte(r, prefix_len, b, prefix);
}

fn encodeString(w :std.io.AnyWriter,comptime prefix :u8,str :[]const u8) anyerror!void {
    const len = huffmanLength(str);
    if (len > str.len) {
        try encodeInteger(w, 7, 0x7f&prefix, @intCast(str.len));
        try w.writeAll(str);
    }
    else {
        try encodeInteger(w, 7, 0x80|prefix, @intCast(len));
        var bitWriter = huffman.BitWriter.init(w);
        for (str) |c| {
            try huffman.codes[c].write(&bitWriter);
        }
        while (bitWriter.bit_count != 0) {
            try bitWriter.writeBits(@as(u1,1),1);
        }
    }
}


fn decodeSingleChar(r :*huffman.BitReader,allone :*u32) anyerror!huffman.HuffmanTree {
    var node = huffman.getRoot();
    while(true) {
        if(node.has_value()) {
            return node;
        }
        const bit = if(r.readBitsNoEof(u1,1)) |x| x else |x| {
            if(x == error.EndOfStream and  node.data == huffman.getRoot().data) {
                return error.HpackHuffmanFinished;
            }
            return x;
        };
        allone.* = if ((allone.* != 0) and (bit != 0)) allone.* + 1 else 0;
        node = try huffman.get_next(node, bit);
    }
}

pub const U8Array = std.ArrayList(u8);

fn decodeHuffmanString(alloc :std.mem.Allocator, r :std.io.AnyReader) anyerror!U8Array {
    var bitReader = huffman.BitReader.init(r);
    var result = U8Array.init(alloc);
    while(true) {
        var allone :u32 = 1;
        const node = decodeSingleChar(&bitReader, &allone);
        if(node) |n| {
            if(n.get_value() == 256) {
                return error.OutOfRange;
            }
            try result.append(@intCast( n.get_value()));
        } else |x| {
            if(x == error.HpackHuffmanFinished or (x == error.EndOfStream) and (allone != 0 and allone - 1 <= 7)) {
                break;
            }
            return x;
        }
    }
    return result;
}

pub fn u8ArrayFromStr(alloc :std.mem.Allocator, str :[]const u8) !U8Array {
    var ret = U8Array.init(alloc);
    try ret.appendSlice(str);
    return ret;
}

fn decodeStringWithLenPrefix(alloc :std.mem.Allocator,r :std.io.AnyReader,len :u64,prefix :u8) anyerror!U8Array {
    var str = U8Array.init(alloc);
    try str.resize(len);
    try r.readNoEof(str.items);
    if(prefix & 0x80 != 0) {
        var s = std.io.fixedBufferStream(str.items);
        const r2 = s.reader().any();
        return decodeHuffmanString(alloc, r2);
    }
    else {
        return str;
    }
}

pub fn decodeString(alloc :std.mem.Allocator, r :std.io.AnyReader) anyerror!U8Array {
    var prefix :u8 = 0;
    const len =try decodeInteger(r, 7, &prefix);
    return decodeStringWithLenPrefix(alloc,r,len,prefix);
}

pub fn decodeStringWithFirstByte(alloc :std.mem.Allocator,r :std.io.AnyReader,first_byte :u8) anyerror!U8Array {
    var prefix :u8 = 0;
    const len =try decodeIntegerWithFirstByte(r, 7, first_byte, &prefix);
    return decodeStringWithLenPrefix(alloc,r,len,prefix);
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
    index :u64,
};

const FieldType = enum {
    index,
    index_literal_insert,
    index_literal_never_indexed,
    index_literal_no_insert,
    dyn_table_update,
    undefined,
};

fn maskFieldType(comptime t :FieldType) u8 {
    return switch(t) {
        FieldType.index => 0x80,
        FieldType.index_literal_insert => 0xC0,
        FieldType.index_literal_never_indexed => 0xF0,
        FieldType.index_literal_no_insert => 0xF0,
        FieldType.dyn_table_update => 0xE0,
        FieldType.undefined => @compileError("undefined"),
    };
}

fn matchFieldType(comptime t :FieldType) u8 {
    return switch(t) {
        FieldType.index => 0x80,
        FieldType.index_literal_insert => 0x40,
        FieldType.index_literal_never_indexed => 0x20,
        FieldType.index_literal_no_insert => 0x00,
        FieldType.dyn_table_update => 0x10,
        FieldType.undefined => @compileError("undefined")
    };
}

fn equalKey(key1 :[]const u8,key2 :[]const u8) bool {
    if(key1.len != key2.len) {
        return false;
    }
    var i :u32 = 0;
    while( i < key1.len) {
        if(key1[i] != key2[i]) {
            return false;
        }
        i += 1;
    }
    return true;
}

fn getTableEntry(table :?*Table,key :[]const u8, value :[]const u8,only_hdr_equal :bool) ?KeyValEntry {
    for(predefinedHeaders,0..) |entry,i| {
        if(!only_hdr_equal) {
            if(equalKey(key, entry.key) and equalKey(value, entry.value)) {
                return KeyValEntry{.keyvalue = entry, .index = i};
            }
        }
        else {
            if(equalKey(key, entry.key)) {
                return KeyValEntry{.keyvalue = entry, .index = i};
            }
        }
    }
    if(table) |t| {
        for(t.entries.buf,predefinedHeaders.len..) |x,i| {
            const entry :AllocatedKeyValue = x;
            if(!only_hdr_equal) {
                if(equalKey(key, entry.key.items) and equalKey(value, entry.value.items)) {
                    return KeyValEntry{.keyvalue = KeyValue{.key = x.key.items,.value = x.value.items}, .index = i};
                }
            }
            else {
                if(equalKey(key, entry.key.items)) {
                    return KeyValEntry{.keyvalue = KeyValue{.key = x.key.items,.value = x.value.items}, .index = i};
                }
            }
        }
    }
    return null;
}

fn isFieldType(t :u8,comptime m :FieldType) bool {
    return maskFieldType(m) & t == matchFieldType(m); 
}

fn getFieldType(t :u8) FieldType {
    if(isFieldType(t,FieldType.index)) {
        return FieldType.index;
    }
    if(isFieldType(t,FieldType.index_literal_insert)) {
        return FieldType.index_literal_insert;
    }
    if(isFieldType(t,FieldType.index_literal_never_indexed)) {
        return FieldType.index_literal_never_indexed;
    }
    if(isFieldType(t,FieldType.index_literal_no_insert)) {
        return FieldType.index_literal_no_insert;
    }
    if(isFieldType(t,FieldType.dyn_table_update)) {
        return FieldType.dyn_table_update;
    }
    return FieldType.undefined;
} 

const StrHasher = struct {
    pub fn eql(_:StrHasher, a :U8Array, b :U8Array,_ :usize) bool {
        return equalKey(a.items, b.items);
    }

    pub fn hash(_:StrHasher, a :U8Array) u32 {
        var hasher = std.hash.Fnv1a_32.init();
        const item = a.items;
        std.hash.autoHashStrat(&hasher,item,.Deep);
        return hasher.final();
    }
};

pub fn addHeader(alloc :std.mem.Allocator, hdr :*Header, key :[]const u8,values :[]const u8) !void  {
    const key_array = try u8ArrayFromStr(hdr.allocator,key);
    const hdr_entry = try hdr.getOrPut(key_array);
    if(!hdr_entry.found_existing) {
        hdr_entry.value_ptr.* = SameKey.init(alloc);
    }
    else {
        key_array.deinit();
    }
    try hdr_entry.value_ptr.*.append(try u8ArrayFromStr(hdr.allocator,values));
}

pub fn equalHeader(hdr1 :Header,hdr2 :Header) bool {
    if(hdr1.count() != hdr2.count()) {
        return false;
    }
    var iter1 = hdr1.iterator();
    while(iter1.next()) |entry1| {
        const entry2  =if (hdr2.get(entry1.key_ptr.*)) |x| x else return false;
        if(entry1.value_ptr.*.items.len != entry2.items.len) {
            return false;
        }
        const iter3 = entry1.value_ptr.*.items;
        for(iter3) |v1| {
            var found = false;
            for(entry2.items) |v2| {
                if(equalKey(v1.items, v2.items)) {
                    found = true;
                    break;
                }
            }
            if(!found) {
                return false;
            }
        }
    }
    return true;
}

pub const SameKey = std.ArrayList(U8Array);
pub const Header = std.ArrayHashMap(U8Array,SameKey,StrHasher,true);

const AllocatedKeyValue = struct {
    key :U8Array,
    value :U8Array,
};

const FIFO = std.fifo.LinearFifo(AllocatedKeyValue,.Dynamic);
pub const Table = struct {
    entries :FIFO,
    max_size :u64,
    size :u64,

    pub fn insert(self :*Table, alloc :std.mem.Allocator,key :[]const u8,value :[]const u8) !void {
        if(self.size + key.len + value.len > self.max_size) {
            while(self.size + key.len + value.len > self.max_size) {
                const removed = if (self.entries.readItem()) |x| x else @panic("Table is empty but size is greater than max_size");
                self.size -= removed.key.items.len + removed.value.items.len;
                removed.key.deinit();
                removed.value.deinit();
            }
        }
        // https://www.rfc-editor.org/rfc/rfc7541.html#section-4.1 
        // 4.1.  Calculating Table Size 
        // It is not an error to
        // attempt to add an entry that is larger than the maximum size; an
        // attempt to add an entry larger than the maximum size causes the table
        // to be emptied of all existing entries and results in an empty table.
        if (key.len + value.len > self.max_size) {
            return;
        }
        const key_array = try u8ArrayFromStr(alloc,key);
        const value_array = try u8ArrayFromStr(alloc,value);
        const entry = AllocatedKeyValue{.key = key_array,.value = value_array};
        try self.entries.writeItem(entry);
        self.size += key.len + value.len;
    }
};

fn appendHeaderDynamic(alloc :std.mem.Allocator,hdr :*Header,key :U8Array,value :U8Array) !void {
    const hdr_entry = try hdr.getOrPut(key);
    if(!hdr_entry.found_existing) {
        hdr_entry.value_ptr.* = SameKey.init(alloc);
    }
    else {
        key.deinit();
    }
    try hdr_entry.value_ptr.*.append(value);
}


fn appendHeader(alloc :std.mem.Allocator, hdr :*Header,key :[]const u8,value :[]const u8) !void {
    const key_array = try u8ArrayFromStr(hdr.allocator,key);
    const hdr_entry = try hdr.getOrPut(key_array);
    if(!hdr_entry.found_existing) {
        hdr_entry.value_ptr.* = SameKey.init(alloc);
    }
    else {
        key_array.deinit();
    }
    try hdr_entry.value_ptr.*.append(try u8ArrayFromStr(hdr.allocator,value));
}

fn lookupTableIndex(index :u64,table :?*Table) !KeyValEntry {
    if(index < predefinedHeaders.len) {
        return KeyValEntry{.keyvalue = predefinedHeaders[index], .index = index};
    }
    if(table) |*t| {
        for(t.*.entries.buf,predefinedHeaders.len..) |x,i| {
            if(i == index) {
                return KeyValEntry{.keyvalue = KeyValue{.key = x.key.items,.value = x.value.items}, .index = i};
            }
        }
    
    }
    return error.TableOutOfRange;
}

pub fn decodeField(alloc :std.mem.Allocator,header :*Header, table :?*Table, r :std.io.AnyReader,first_byte :u8) !void  {
    const b = first_byte;
    switch(getFieldType(b)) {
       FieldType.index => {
            const index  =  try decodeIntegerWithFirstByte(r, 7, b,null);
            const entry = try lookupTableIndex(index,table);
            try appendHeader(alloc,header,entry.keyvalue.key,entry.keyvalue.value);
        },
        FieldType.index_literal_insert => {
            const index  =  try decodeIntegerWithFirstByte(r, 6, b,null);
            var key :U8Array= undefined;
            var value :U8Array = undefined;
            if(index == 0) {
                key = try decodeString(alloc,r);
                value = try decodeString(alloc,r);
            }
            else {
                const entry = try lookupTableIndex(index,table);
                key = try u8ArrayFromStr(alloc,entry.keyvalue.key);
                value = try decodeString(alloc,r);
            }
            if(table) |t| {
                try t.insert(alloc,key.items,value.items);
            } 
            else {
                return error.DynamicTableNotSupported;
            }
            try appendHeaderDynamic(alloc,header,key,value);
            
        },
        FieldType.index_literal_no_insert , FieldType.index_literal_never_indexed => {
            const index  =  try decodeIntegerWithFirstByte(r, 4, b,null);
            var key :U8Array= undefined;
            var value :U8Array = undefined;
            if(index == 0) {
                key = try decodeString(alloc,r);
                value = try decodeString(alloc,r);
            }
            else {
                const entry = try lookupTableIndex(index,table);
                key = try u8ArrayFromStr(alloc,entry.keyvalue.key);
                value = try decodeString(alloc,r);
            }
            try appendHeaderDynamic(alloc,header, key,value); 
        },
        FieldType.dyn_table_update => {
            return error.OutOfRange; // currently not supported
        },
        FieldType.undefined => {
            return error.OutOfRange;
        },
    }
}


fn checkShouldAdd(shouldAdd :anytype,comptime field :FieldType,key :[]const u8, value :[]const u8) bool {
    const ty  :std.builtin.Type = @typeInfo(@TypeOf(shouldAdd));
    switch(ty) {
        .Fn => |*f| {
            const t = if(f.return_type) |t| t else {
                @compileError("shouldAdd function must return a boolean");
            };
            if(t != bool) {
                @compileError("shouldAdd function must return a boolean");   
            }
            if(f.params.len != 3) {
                @compileError("shouldAdd function must have 3 parameters");
            }
            return shouldAdd(key,value,field);
        },
        else => {} 
    }
    return false;
}

pub fn encodeField(alloc :std.mem.Allocator, w :std.io.AnyWriter,entry :KeyValue,table :?*Table, shouldAdd :anytype) !void {
    // exact match
    const matched = getTableEntry(table,entry.key,entry.value,false);
    if(matched) |x| {
        try encodeInteger(w,7,matchFieldType(FieldType.index), @intCast(x.index));
        return;
    }
    // key match
    const matched_key = getTableEntry(table,entry.key,entry.value,true);
    if (matched_key) |x| {
        if(table) |t| {
            if(checkShouldAdd(shouldAdd,FieldType.index_literal_insert,entry.key,entry.value)) {
                try encodeInteger(w,6,matchFieldType(FieldType.index_literal_insert),@intCast(x.index));
                try encodeString(w,0,entry.value);
                try t.insert(alloc,entry.key,entry.value);
                return;
            }
        }
        try encodeInteger(w,4,matchFieldType(FieldType.index_literal_no_insert),@intCast(x.index));
        try encodeString(w,0,entry.value);
        return;
    }
    if(table) |t| {
        if(checkShouldAdd(shouldAdd,FieldType.index_literal_insert,entry.key,entry.value)) {
            try encodeInteger(w,6,matchFieldType(FieldType.index_literal_insert),0);
            try encodeString(w,0,entry.key);
            try encodeString(w,0,entry.value);
            try t.insert(alloc,entry.key,entry.value);
            return;
        }
    }
    try encodeInteger(w,4,matchFieldType(FieldType.index_literal_no_insert),0);
    try encodeString(w,0,entry.key);
    try encodeString(w,0,entry.value);
}

pub fn encodeHeader(alloc :std.mem.Allocator,w :std.io.AnyWriter,header :Header,table :?*Table,shouldAdd :anytype) !void {
    var iter = header.iterator();
    while(iter.next()) |entry| {
        const value_iter = entry.value_ptr.*.items;
        for(value_iter) |v| {
            const key :U8Array = entry.key_ptr.*;
            const value :U8Array = v;
            try encodeField(alloc,w,KeyValue{.key = key.items ,.value = value.items},table,shouldAdd);
        }
    }
}

pub fn decodeHeader(alloc :std.mem.Allocator,r :std.io.AnyReader,table :?*Table) !Header {
    var header = Header.init(alloc);
    while(true) {
        const b = r.readByte();
        if(b) |first_byte| {
            try decodeField(alloc,&header,table,r,first_byte);
        }
        else |err| {
            if(err == error.EndOfStream) {
                break;
            }
            return err;
        }
    }
    return header;
}

fn printHeader(header :Header) !void {
    var iter = header.iterator();
    const stdout = std.io.getStdOut().writer();
    while(iter.next()) |field| {
        const key :U8Array = field.key_ptr.*;
        for(field.value_ptr.*.items) |v| {
            const value :U8Array = v;
            try stdout.print("{s}: {s}\n", .{key.items, value.items});
        }
    }

}
test "http2 header encode/decode" {
    const hpack = @This();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var header :hpack.Header = hpack.Header.init(alloc); 
    try hpack.addHeader(alloc,&header, ":method", "GET");
    try hpack.addHeader(alloc,&header, ":scheme", "https");
    try hpack.addHeader(alloc,&header, ":path", "/");
    try hpack.addHeader(alloc,&header, ":authority", "www.example.com");
    try hpack.addHeader(alloc,&header, "custom-key", "custom-value");
    var buffer: [1000]u8 = undefined;
    var stream = std.io.fixedBufferStream(buffer[0..]);
    try hpack.encodeHeader(alloc,stream.writer().any(), header,null,null);
    var reader = std.io.fixedBufferStream(stream.getWritten());
    const decodedHeader = try hpack.decodeHeader(alloc, reader.reader().any(),null);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Header\n",.{});
    try printHeader(header);
    try stdout.print("Decoded Header\n",.{});
    try printHeader(decodedHeader);
    try std.testing.expect(hpack.equalHeader(header,decodedHeader));
}