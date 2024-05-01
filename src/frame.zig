const std = @import("std");
const hpack = @import("hpack.zig");
pub const H2FrameType = enum(u8) {
    DATA,
    HEADERS,
    PRIORITY,
    RST_STREAM,
    SETTINGS,
    PUSH_PROMISE,
    PING,
    GOAWAY,
    WINDOW_UPDATE,
    CONTINUATION,
};

const Flags = @import("Flags.zig");

const Self = @This();


peer_max_frame_size :u24 = settings.initialMaxFrameSize,
local_max_frame_size :u24 = settings.initialMaxFrameSize,


const FrameHeader = struct {
    const Self = FrameHeader;
    length: u24,
    typ: union(enum) {
        typ :H2FrameType,
        unknown_type:u8,
    },
    flags: Flags,
    stream_id: ID,
};

fn encodeFrameHeader(frame :FrameHeader,enc :std.io.AnyWriter) anyerror!void{
    try enc.writeInt(u24, frame.length,.big);
    try enc.writeByte(@as(u8, switch(frame.typ) {
        .typ => |t| @intFromEnum(t),
        .unknown_type => |t| t,
    }));
    try enc.writeByte(@as(u8,frame.flags.value));
    try enc.writeInt(u32, @as(u32,frame.stream_id),.big);
}

fn intToType(t :u8) ?H2FrameType {
    switch(t) {
        0 => return H2FrameType.DATA,
        1 => return H2FrameType.HEADERS,
        2 => return H2FrameType.PRIORITY,
        3 => return H2FrameType.RST_STREAM,
        4 => return H2FrameType.SETTINGS,
        5 => return H2FrameType.PUSH_PROMISE,
        6 => return H2FrameType.PING,
        7 => return H2FrameType.GOAWAY,
        8 => return H2FrameType.WINDOW_UPDATE,
        9 => return H2FrameType.CONTINUATION,
        else => return null,
    }
}

pub fn decodeFrameHeader(self: Self,enc :std.io.AnyReader) anyerror!FrameHeader {
    var hdr :FrameHeader = undefined;
    hdr.length = try enc.readInt( u24,.big);
    hdr.typ = .{.unknown_type = try enc.readByte()};
    if(intToType(hdr.typ.unknown_type)) |typ| {
        hdr.typ = .{.typ = typ};
    }
    hdr.flags.value = try enc.readByte();
    const valID = try enc.readInt(u32,.big);
    if(valID > 0x7FFFFFFF) {
        return error.InvalidStreamIDReservedBit;
    }
    hdr.stream_id = @intCast( valID);
    if(self.local_max_frame_size < hdr.length) {
        return error.TooLongFrameSize;
    }
    return hdr;
}

const ID = u31;

pub const CONNECTION :ID = 0;

fn encodeHeader(self :Self, enc :std.io.AnyWriter, id :ID,typ :H2FrameType,flags :Flags,len :usize) !void {
    if(len > 0x00FFFFFF) {
        return error.TooLongData;
    }
    if(len > self.peer_max_frame_size) {
        return error.TooLongFrameSize;
    }
    const hdr = FrameHeader{
        .length = @intCast(len),
        .typ = .{.typ = typ},
        .flags = flags,
        .stream_id = id,
    };
    try encodeFrameHeader(hdr,enc);
}

fn mayWritePadding(len :?u8,enc :std.io.AnyWriter) !void {
    if(len) |p| {
        try enc.writeByteNTimes(0, p);
    }
}

/// https://www.rfc-editor.org/rfc/rfc9113.html#name-data
pub fn encodeData(self :Self,enc :std.io.AnyWriter,id :ID,data :[]const u8, endOfStream :bool, padding:?u8) !void {
    if(id == CONNECTION) {
        return error.InvalidStreamID0;
    }
    var flags = Flags.init();
    if (endOfStream) {
        flags.set_end_stream();
    }
    if (padding) |pad| {
        flags.set_padded();
        try self.encodeHeader(enc,id,H2FrameType.DATA,flags,data.len + 1 + pad);
        try enc.writeByte(pad);
        try enc.writeAll(data);
        try enc.writeByteNTimes(0, pad);
    }
    else {
        try self.encodeHeader(enc,id,H2FrameType.DATA,flags,data.len);
        try enc.writeAll(data);
    }
}

pub const Priority = struct {
    exclusive: bool,
    stream_dependency: ID,
    weight: u8,

    fn encode(self :Priority) [5]u8 {
        var buf :[5]u8 = undefined;
        buf[0] = if (self.exclusive) 0x80 else 0;
        buf[0] |= @intCast((self.stream_dependency >> 24) & 0x7F);
        buf[1] = @intCast((self.stream_dependency >> 16) & 0xFF);
        buf[2] = @intCast((self.stream_dependency >> 8) & 0xFF);
        buf[3] = @intCast(self.stream_dependency & 0xFF);
        buf[4] = self.weight;
        return buf;
    }
};


fn encodeContinuations(self :Self, base :[]const u8,enc :std.io.AnyWriter,id :ID) !void {
    var flags = Flags.init();
    var len :usize = 0;
    var slice = base;
    while(slice.len > 0) {
        if(slice.len > self.peer_max_frame_size) {
            len = self.peer_max_frame_size;
        }
        else {
            flags.set_end_headers();
            len = slice.len;
        }
        try self.encodeHeader(enc,id,H2FrameType.CONTINUATION,flags,len);
        try enc.writeAll(slice[0..len]);
        slice = slice[len..];
        flags = Flags.init();
    }
}

/// https://www.rfc-editor.org/rfc/rfc9113.html#name-headers
pub fn encodeHeaders(self :Self, alloc :std.mem.Allocator, enc :std.io.AnyWriter,id :ID,endOfStream :bool,header :hpack.Header,table :*hpack.Table,padding :?u8, priority :?Priority) !void  {
    if(id == CONNECTION) {
        return error.InvalidStreamID0;
    }
    const DynamicWriter = std.fifo.LinearFifo(u8,.Dynamic);
    var hpackCompressed :DynamicWriter = DynamicWriter.init(alloc);
    defer hpackCompressed.deinit();
    try hpack.encodeHeader(alloc,hpackCompressed.writer().any(),header,table,null);
    var slice = hpackCompressed.readableSlice(0);
    var flags = Flags.init();
    const optional_fields_len :usize= (if (padding) |p| 1 + p else 0) + (if (priority) |_| @as(usize,5) else 0);
    var len :usize = slice.len + optional_fields_len;
    if(endOfStream) {
        flags.set_end_stream();
    }
    if(padding) |_| {
        flags.set_padded();
    }
    if(priority) |_| {
        flags.set_priority();
    }
    if(len > self.peer_max_frame_size) {
        if(self.peer_max_frame_size < optional_fields_len) {
            return error.InvalidMaxFrameSize;
        }
        len = self.peer_max_frame_size;
    }
    else {
        flags.set_end_headers();
    }
    try self.encodeHeader(enc,id,H2FrameType.HEADERS,flags,len);
    if(padding) |p| {
        try enc.writeByte(p);
        len -= 1 + p;
    }
    if(priority) |p| {
        try enc.writeAll(&p.encode());
        len -= 5;
    }
    try enc.writeAll(slice[0..len]);
    try mayWritePadding(padding,enc);
    try self.encodeContinuations(slice[len..],enc,id);
}

pub fn encodePushPromise(self :Self,alloc :std.mem.Allocator,enc :std.io.AnyWriter,id :ID,promised_stream_id :ID,header :hpack.Header,table :*hpack.Table,padding :?u8) !void {
    if(id == CONNECTION) {
        return error.InvalidStreamID0;
    }
    var flags = Flags.init();
    if(padding) |_| {
        flags.set_padded();
    }
    const DynamicWriter = std.fifo.LinearFifo(u8,.Dynamic);
    var hpackCompressed :DynamicWriter = DynamicWriter.init(alloc);
    defer hpackCompressed.deinit();
    try hpack.encodeHeader(alloc,hpackCompressed.writer().any(),header,table,null);
    var slice = hpackCompressed.readableSlice(0);
    const optional_fields_len :usize= (if(padding) |p| 1 + p else 0) + 4;
    var len = slice.len + optional_fields_len;
    if(len > self.peer_max_frame_size) {
        if(self.peer_max_frame_size < optional_fields_len) {
            return error.InvalidMaxFrameSize;
        }
        len = self.peer_max_frame_size;
    }
    else {
        flags.set_end_headers();
    }
    try self.encodeHeader(enc,id,H2FrameType.PUSH_PROMISE,flags,len);
    if(padding) |p| {
        try enc.writeByte(p);
        len -= 1 + p;
    }
    try enc.writeInt(u32, @as(u32,promised_stream_id),.big);
    len -= 4;
    try enc.writeAll(slice[0..len]);
    try mayWritePadding(padding,enc);
    try self.encodeContinuations(slice[len..],enc,id);
}

const settings = @import("settings.zig");

/// https://www.rfc-editor.org/rfc/rfc9113.html#name-settings
pub fn encodeSettings(self: Self,enc :std.io.AnyWriter,ack :bool, definedSettings :?settings.DefinedSettings, additionalSettings :?[]settings.Setting) !void {
    var flags = Flags.init();
    if(ack) {
        flags.set_ack();
        if(definedSettings) |_| {
            return error.InvalidSettingsAck;
        }
        if(additionalSettings) |_| {
            return error.InvalidSettingsAck;
        }
    }
    const len = if(additionalSettings) |s| s.len * 6 else 0 + if(definedSettings) |x| settings.getEncodedDefinedSettingsLen(x) else 0;
    try self.encodeHeader(enc,CONNECTION,H2FrameType.SETTINGS,flags,len);
    if(!ack) {
        if(definedSettings) |x| {
            try settings.encodeDefinedSettings(enc,x);
        }
        if(additionalSettings) |iter| {
            for(iter) |s| {
                try enc.writeAll(&s.encode());
            }
        }
    }
}

/// https://www.rfc-editor.org/rfc/rfc9113.html#name-goaway
pub fn encodeGoaway(self :Self,enc :std.io.AnyWriter,last_stream_id :ID,error_code :u32,debug_data :?[]const u8) !void {
    const len = 8 + if(debug_data) |d| d.len else 0;
    try self.encodeHeader(enc,CONNECTION,H2FrameType.GOAWAY,Flags.init(),len);
    try enc.writeInt(u32, @as(u32,last_stream_id),.big);
    try enc.writeInt(u32, error_code,.big);
    if(debug_data) |d| try enc.writeAll(d);
}

/// https://www.rfc-editor.org/rfc/rfc9113.html#name-ping
pub fn encodePing(self :Self,enc :std.io.AnyWriter,payload :u64,ack :bool) !void {
    var flags = Flags.init();
    if(ack) {
        flags.set_ack();
    }
    try self.encodeHeader(enc,CONNECTION,H2FrameType.PING,flags,8);
    try enc.writeInt(u64, payload,.big);
}

/// https://www.rfc-editor.org/rfc/rfc9113.html#name-priority
pub fn encodePriority(self :Self,enc :std.io.AnyWriter,id :ID,priority :Priority) !void {
    if(id == CONNECTION) {
        return error.InvalidStreamID0;
    }
    try self.encodeHeader(enc,id,H2FrameType.PRIORITY,Flags.init(),5);
    try enc.writeAll(&priority.encode());
}

/// https://www.rfc-editor.org/rfc/rfc9113.html#name-window_update
pub fn encodeWindowUpdate(self :Self,enc :std.io.AnyWriter,id :ID,increment :u31) !void {
    try self.encodeHeader(enc,id,H2FrameType.WINDOW_UPDATE,Flags.init(),4);
    try enc.writeInt(u32, @as(u32,increment),.big);
}

/// https://www.rfc-editor.org/rfc/rfc9113.html#name-rst_stream
pub fn encodeRstStream(self :Self,enc :std.io.AnyWriter,id :ID,error_code :u32) !void {
    if(id == CONNECTION) {
        return error.InvalidStreamID0;
    }
    try self.encodeHeader(enc,id,H2FrameType.RST_STREAM,Flags.init(),4);
    try enc.writeInt(u32, error_code,.big);
}





const Frame = struct {
    header :FrameHeader,
    payload: union(enum) {
        data :struct {
            padding :?u8,
            data :hpack.U8Array,
        },
        headers :struct {
            header :hpack.Header,
            priority :?Priority,
            padding :?u8,
        },
        priority :Priority,
        rst_stream :struct {
            error_code :u32,
        },
        settings :?std.ArrayList(settings.Setting),
        push_promise :struct {
            promised_stream_id :ID,
            header :hpack.Header,
            padding :?u8,
        },
        ping :u64,
        goaway :struct {
            last_stream_id :ID,
            error_code :u32,
            debug_data :hpack.U8Array,
        },
        window_update :struct {
            increment :u31,
        },
        opaque_data :hpack.U8Array,
    },

    pub fn deinit(self :*Frame) void {
        switch(self.payload) {
            .data => self.payload.data.data.deinit(),
            .headers => self.payload.headers.header.deinit(),
            .push_promise => self.payload.push_promise.header.deinit(),
            .goaway => self.payload.goaway.debug_data.deinit(),
            .opaque_data => self.payload.opaque_data.deinit(),
            .settings => if(self.payload.settings) |x| x.deinit(),
            else => {},
        }
    }
};

fn mayReadPadding(len :?u8, r :std.io.AnyReader) !void {
    if(len) |p| {
        for(0..p) |_| {
            _ = try r.readByte();
        }
    }
}

fn mayReadPadLen(pp :*?u8,len :*u24, r :std.io.AnyReader,frame :*Frame) !void {
    if(frame.header.flags.is_padded()) {
        const pad = try r.readByte();
        if(pad + 1 >= frame.header.length) {
            return error.InvalidPadding;
        }
        pp.* = pad;
        len.* -= 1 + pad;
    }
    else {
        pp.* = null;
    }
}

fn readBytes( len :u24,alloc :std.mem.Allocator, r :std.io.AnyReader) !hpack.U8Array {
    var data = hpack.U8Array.init(alloc);
    errdefer data.deinit();
    try data.resize(len);
    try r.readNoEof(data.items);
    return data;
}

fn readPriority( r :std.io.AnyReader) !Priority {
    const b = try r.readBytesNoEof(5);
    var data :Priority = undefined;
    data.exclusive = b[0] & 0x80 != 0;
    data.stream_dependency = (@as(u31,b[0] & 0x7F) << 24) | (@as(u31,b[1]) << 16) | (@as(u31,b[2]) << 8) | @as(u31,b[3]);
    data.weight = b[4];
    return data;
}

fn mayReadPriority(len :*u24, data :*?Priority,flags :Flags, r :std.io.AnyReader) !void {
    if(flags.is_priority()) {
        if(len.* < 5) {
            return error.InvalidPriority;
        }
        data.* = try readPriority(r);
        len.* -= 5;
    }
    else {
        data.* = null;
    }
}

fn typeIDCheck(comptime typ :H2FrameType,header :FrameHeader,opt :anytype) !void {
    if(header.typ.typ != typ) {
        @panic("Invalid frame type");
    }
    switch(typ) {
        H2FrameType.DATA => {
            if(header.stream_id == CONNECTION) {
                return error.InvalidStreamID0;
            }
        },
        H2FrameType.HEADERS => {
            if(header.stream_id == CONNECTION) {
                return error.InvalidStreamID0;
            }
        },
        H2FrameType.CONTINUATION => {
            const cmpID :ID = opt;
            if(header.stream_id != cmpID) {
                return error.InvalidContinuationStreamID;
            }
        },
        H2FrameType.GOAWAY => {
            if(header.stream_id != CONNECTION) {
                return error.InvalidStreamIDNot0;
            }
        },
        H2FrameType.PING => {
            if(header.stream_id != CONNECTION) {
                return error.InvalidStreamIDNot0;
            }
            if(header.length != 8) {
                return error.InvalidPingLength;
            }
        },
        H2FrameType.PRIORITY => {
            if(header.stream_id == CONNECTION) {
                return error.InvalidStreamID0;
            }
            if(header.length != 5) {
                return error.InvalidPriorityLength;
            }
        },
        H2FrameType.PUSH_PROMISE => {
            if(header.stream_id == CONNECTION) {
                return error.InvalidStreamID0;
            }
            if(header.length < 4) {
                return error.InvalidPushPromiseLength;
            }
        },
        H2FrameType.RST_STREAM => {
            if(header.stream_id == CONNECTION) {
                return error.InvalidStreamID0;
            }
        },
        H2FrameType.SETTINGS => {
            if(header.stream_id != CONNECTION) {
                return error.InvalidStreamIDNot0;
            }
            if(header.flags.is_ack()  ) {
                if(header.length != 0) {
                    return error.InvalidSettingsAckLength;
                }
            }
            else if(!header.flags.is_ack() ) {
                if(header.length % 6 != 0) {
                    return error.InvalidSettingsLength;
                }
            }
        },
        H2FrameType.WINDOW_UPDATE => {
            if(header.length != 4) {
                return error.InvalidWindowUpdateLength;
            }
        },
    }
}
 
fn decodeData(alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame)  !void {
    try typeIDCheck(H2FrameType.DATA,frame.header,null);
    var len = frame.*.header.length;
    try mayReadPadLen(&frame.payload.data.padding,&len,r,frame);
    frame.payload.data.data = try readBytes(len,alloc,r);
    try mayReadPadding(frame.payload.data.padding,r);
}

fn mayReadCONTINUATIONs(self :Self,r :std.io.AnyReader,headerCompressed :*hpack.U8Array,flags :Flags,cmpID :ID) !void {
    if(flags.is_end_headers()) {
        return;
    }
    while(true) {
        const hdr = try self.decodeFrameHeader(r);
        try typeIDCheck(H2FrameType.CONTINUATION,hdr,cmpID);
        const oldLen = headerCompressed.items.len;
        try headerCompressed.resize(oldLen + hdr.length);
        try r.readNoEof(headerCompressed.items[oldLen..]);
        if(hdr.flags.is_end_headers()) {
            break;
        }
    }
}

fn decodeHeaders(self :Self,table :*hpack.Table, alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.HEADERS,frame.header,null);
    var len = frame.*.header.length;
    frame.payload = .{.headers = undefined};
    try mayReadPadLen(&frame.payload.headers.padding,&len,r,frame);
    try mayReadPriority(&len,&frame.payload.headers.priority,frame.header.flags,r);
    var headerCompressed = try readBytes(len,alloc,r);
    defer headerCompressed.deinit();
    try mayReadPadding(frame.payload.headers.padding,r);
    try self.mayReadCONTINUATIONs(r,&headerCompressed,frame.header.flags,frame.header.stream_id);
    var stream =  std.io.fixedBufferStream(headerCompressed.items);
    frame.payload.headers.header = try hpack.decodeHeader(alloc,stream.reader().any(),table);
}

fn decodeSettings(alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.SETTINGS,frame.header,null);
    if(frame.header.length == 0) {
        frame.payload = .{.settings = null};
        return;
    }
    frame.payload = .{.settings = std.ArrayList(settings.Setting).init(alloc)};
    try frame.payload.settings.?.resize(frame.header.length / 6);
    for(frame.payload.settings.?.items) |*s| {
        s.id = try r.readInt(u16,.big);
        s.value = try r.readInt(u32,.big);
    }
}

fn decodeGoaway(alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.GOAWAY,frame.header,null);
    if(frame.header.length < 8) {
        return error.InvalidGoawayLength;
    }
    const last_id = try r.readInt(u32,.big);
    if(last_id > 0x7FFFFFFF) {
        return error.InvalidStreamIDReservedBit;
    }
    frame.payload = .{.goaway = undefined};
    frame.payload.goaway.last_stream_id = @intCast(last_id);
    frame.payload.goaway.error_code = try r.readInt(u32,.big);
    frame.payload.goaway.debug_data = try readBytes(frame.header.length - 8,alloc,r);
}

fn decodePing(r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.PING,frame.header,null);
    frame.payload = .{.ping = try r.readInt(u64,.big)};
}

fn decodeWindowUpdate(r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.WINDOW_UPDATE,frame.header,null);
    const update = try r.readInt(u32,.big);
    if(update > 0x7FFFFFFF) {
        return error.InvalidStreamIDReservedBit;
    }
    if(update == 0) {
        return error.InvalidWindowUpdateIncrement;
    }
    frame.payload = .{.window_update = .{ .increment = @intCast(update) }};
}
fn decodeRstStream(r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.RST_STREAM,frame.header,null);
    frame.payload = .{.rst_stream = .{.error_code =try r.readInt(u32,.big)}};
}

fn decodePushPromise(self :Self,table :*hpack.Table, alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame)!void {
    try typeIDCheck(H2FrameType.PUSH_PROMISE,frame.header,null);
    var len = frame.*.header.length;
    frame.payload = .{.push_promise = undefined};
    try mayReadPadLen(&frame.payload.push_promise.padding,&len,r,frame);
    const promise_id = try r.readInt(u32,.big);
    if(promise_id > 0x7FFFFFFF) {
        return error.InvalidStreamIDReservedBit;
    }
    if(promise_id == CONNECTION) {
        return error.InvalidStreamID0;
    }
    if(len < 4) {
        return error.InvalidPushPromiseLength;
    }
    len -= 4;
    frame.payload.push_promise.promised_stream_id = @intCast(promise_id);
    var headerCompressed = try readBytes(len,alloc,r);
    defer headerCompressed.deinit();
    try mayReadPadding(frame.payload.push_promise.padding,r);
    try self.mayReadCONTINUATIONs(r,&headerCompressed,frame.header.flags,frame.payload.push_promise.promised_stream_id);
    var stream =  std.io.fixedBufferStream(headerCompressed.items);
    frame.payload.push_promise.header = try hpack.decodeHeader(alloc,stream.reader().any(),table);
}

pub fn decodeFramesWithHeader(self :Self,hdr :FrameHeader, alloc :std.mem.Allocator, r :std.io.AnyReader,table :*hpack.Table) !Frame {
    var frame = Frame{ .header = hdr, .payload = undefined };
    errdefer frame.deinit();
    switch(frame.header.typ) {
        .typ =>|t| switch(t) {
            H2FrameType.DATA => {
                try decodeData(alloc,r,&frame);
            },
            H2FrameType.HEADERS => {
                try self.decodeHeaders(table,alloc,r,&frame);
            },
            H2FrameType.CONTINUATION => {
                return error.InvalidContinuation;
            },
            H2FrameType.SETTINGS => {
                try decodeSettings(alloc,r,&frame);
            },
            H2FrameType.GOAWAY => {
                try decodeGoaway(alloc,r,&frame);
            },
            H2FrameType.PING => {
                try decodePing(r,&frame);
            },
            H2FrameType.PRIORITY => {
                try typeIDCheck(H2FrameType.PRIORITY,frame.header,null);
                frame.payload = .{.priority = try readPriority(r)};
            },
            H2FrameType.WINDOW_UPDATE => {
                try decodeWindowUpdate(r,&frame);
            },
            H2FrameType.RST_STREAM => {
                try decodeRstStream(r,&frame);
            },
            H2FrameType.PUSH_PROMISE => {
                try self.decodePushPromise(table,alloc,r,&frame);
            }
        },
        else => {
            frame.payload.opaque_data =  try readBytes(frame.header.length,alloc,r);
        }
    }
    return frame;
}

/// Decode one or more frames from the reader.
/// if frame is a HEADER or PUSH_PROMISE frame and the END_HEADERS flag is not set, the function will read the CONTINUATION frames.
/// and decode the headers.
pub fn decodeFrames(self :Self, alloc :std.mem.Allocator, r :std.io.AnyReader,table :*hpack.Table) !Frame {
    const hdr :FrameHeader= try self.decodeFrameHeader(r);
    return try self.decodeFramesWithHeader(hdr,alloc,r,table);
} 

pub fn init() Self {
    return Self{ };
}


test "frame encode decode test" {
   const frame = Self;
   var gpa = std.heap.GeneralPurposeAllocator(.{}){};
   const alloc = gpa.allocator();
   defer _ = gpa.deinit();
   var buf: [1024 * 10]u8 = undefined;
   var s =  std.io.fixedBufferStream(buf[0..]);
   const framer = frame.init();
   var hdr =  hpack.Header.init(alloc);   
   defer hdr.deinit();
   var encoder_table = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
   defer encoder_table.deinit();
   var decoder_table = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
   defer decoder_table.deinit();
   for(0..100) |_| {
      try hpack.addHeader(alloc, &hdr, "x-test", "test");
      try hpack.addHeader(alloc, &hdr, "content-type", "text/html");
      try hpack.addHeader(alloc, &hdr, "content-length", "0");
      try hpack.addHeader(alloc, &hdr, "date", "Mon, 21 Oct 2013 20:13:21 GMT");
   }
   try framer.encodeSettings(s.writer().any(),false,settings.DefinedSettings{.enablePush = false},null);
   try framer.encodeSettings(s.writer().any(),true,null,null);
   try framer.encodeHeaders(alloc, s.writer().any(),1,false,hdr,&encoder_table,null,null);
   try framer.encodeData(s.writer().any(),1,"Hello World from Zig!",true,null);
   try framer.encodePing(s.writer().any(),0x12345678,false);
   try framer.encodePing(s.writer().any(),0x12345678,true);
   try framer.encodePriority(s.writer().any(),1,.{.stream_dependency = 1, .weight = 0, .exclusive = false});
   try framer.encodeWindowUpdate(s.writer().any(),1,0x1000);
   try framer.encodeWindowUpdate(s.writer().any(),frame.CONNECTION,0x1000);
   try framer.encodePushPromise(alloc,s.writer().any(),1,2,hdr,&encoder_table,null);
   try framer.encodeRstStream(s.writer().any(),1,0);
   try framer.encodeGoaway(s.writer().any(),1,0,null);
   s.reset();
   
   
   var d = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer d.deinit();
   try std.testing.expectEqual(d.header.stream_id,frame.CONNECTION);
   try std.testing.expectEqual(d.header.typ.typ,frame.H2FrameType.SETTINGS);
   try std.testing.expectEqual(d.header.flags,Flags.init());
   try std.testing.expectEqual(d.header.length,6);
   var d2 = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer d2.deinit();
   try std.testing.expectEqual(d2.header.stream_id,frame.CONNECTION);
   try std.testing.expectEqual(d2.header.typ.typ,frame.H2FrameType.SETTINGS);
   try std.testing.expectEqual(d2.header.flags,Flags.initValue(Flags.ACK));
   try std.testing.expectEqual(d2.header.length,0);   
   var h = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer h.deinit();
   try std.testing.expectEqual(h.header.stream_id,1);
   try std.testing.expectEqual(h.header.typ.typ,frame.H2FrameType.HEADERS);
   try std.testing.expectEqual(h.header.flags,Flags.initValue(Flags.END_HEADERS));
   const stdout = std.io.getStdOut().writer();
   try hpack.printHeader(stdout,h.payload.headers.header);
   try hpack.printHeader(stdout,hdr);
   try std.testing.expect(hpack.equalHeader(hdr,h.payload.headers.header));
   var b = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer b.deinit();
   try std.testing.expectEqual(b.header.stream_id,1);
   try std.testing.expectEqual(b.header.typ.typ,frame.H2FrameType.DATA);
   try std.testing.expectEqual(b.header.flags,Flags.initValue(Flags.END_STREAM));
   try std.testing.expectEqualStrings( b.payload.data.data.items, "Hello World from Zig!");
   var p = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer p.deinit();
   try std.testing.expectEqual(p.header.stream_id,frame.CONNECTION);
   try std.testing.expectEqual(p.header.typ.typ,frame.H2FrameType.PING);
   try std.testing.expectEqual(p.header.flags,Flags.init());
   try std.testing.expectEqual(p.payload.ping,0x12345678);
   var p2 = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer p2.deinit();
   try std.testing.expectEqual(p2.header.stream_id,frame.CONNECTION);
   try std.testing.expectEqual(p2.header.typ.typ,frame.H2FrameType.PING);
   try std.testing.expectEqual(p2.header.flags,Flags.initValue(Flags.ACK));
   try std.testing.expectEqual(p2.payload.ping,0x12345678);
   var pr = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer pr.deinit();
   try std.testing.expectEqual(pr.header.stream_id,1);
   try std.testing.expectEqual(pr.header.typ.typ,frame.H2FrameType.PRIORITY);
   try std.testing.expectEqual(pr.header.flags,Flags.init());
   try std.testing.expectEqual(pr.payload.priority.stream_dependency,1);
   try std.testing.expectEqual(pr.payload.priority.weight,0);
   try std.testing.expectEqual(pr.payload.priority.exclusive,false);
   var w = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer w.deinit();
   try std.testing.expectEqual(w.header.stream_id,1);
   try std.testing.expectEqual(w.header.typ.typ,frame.H2FrameType.WINDOW_UPDATE);
   try std.testing.expectEqual(w.header.flags,Flags.init());
   try std.testing.expectEqual(w.payload.window_update.increment,0x1000);
   var w2 = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer w2.deinit();
   try std.testing.expectEqual(w2.header.stream_id,frame.CONNECTION);
   try std.testing.expectEqual(w2.header.typ.typ,frame.H2FrameType.WINDOW_UPDATE);
   try std.testing.expectEqual(w2.header.flags,Flags.init());
   try std.testing.expectEqual(w2.payload.window_update.increment,0x1000);
   var c = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer c.deinit();
   try std.testing.expectEqual(c.header.stream_id,1);
   try std.testing.expectEqual(c.header.typ.typ,frame.H2FrameType.PUSH_PROMISE);
   try std.testing.expectEqual(c.header.flags,Flags.initValue(Flags.END_HEADERS));
   try std.testing.expectEqual(c.payload.push_promise.promised_stream_id,2);
   try std.testing.expect(hpack.equalHeader(hdr,c.payload.push_promise.header));
   var r = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer r.deinit();
   try std.testing.expectEqual(r.header.stream_id,1);
   try std.testing.expectEqual(r.header.typ.typ,frame.H2FrameType.RST_STREAM);
   try std.testing.expectEqual(r.header.flags,Flags.init());
   try std.testing.expectEqual(r.payload.rst_stream.error_code,0);
   var g = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);   
   defer g.deinit();   
   try std.testing.expectEqual(g.header.stream_id,frame.CONNECTION);
   try std.testing.expectEqual(g.header.typ.typ,frame.H2FrameType.GOAWAY);
   try std.testing.expectEqual(g.header.flags,Flags.init());
   try std.testing.expectEqual(g.payload.goaway.last_stream_id,1);
   try std.testing.expectEqual(g.payload.goaway.error_code,0);
   try std.testing.expectEqual(g.payload.goaway.debug_data.items.len,0);
}