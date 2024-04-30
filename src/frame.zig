const std = @import("std");
const hpack = @import("hpack.zig");
const H2FrameType = enum(u8) {
    DATA,
    HEADDER,
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
        1 => return H2FrameType.HEADDER,
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

fn decodeFrameHeader(self: Self,enc :std.io.AnyReader) anyerror!FrameHeader {
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

const CONNECTION :ID = 0;

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

//https://www.rfc-editor.org/rfc/rfc9113.html#name-data
pub fn encodeData(self :Self,enc :std.io.AnyWriter,id :ID,data :[]u8, endOfStream :bool, padding:?u8) !void {
    var flags = Flags.init();
    if (endOfStream) {
        flags.set_end_stream();
    }
    if (padding) |pad| {
        flags.set_padded();
        try self.encodeHeader(enc,id,H2FrameType.DATA,flags,data.len + 1 + pad);
        try enc.writeByte(pad);
        try enc.write(data);
        try enc.writeByteNTimes(0, pad);
    }
    else {
        try encodeHeader(enc,id,H2FrameType.DATA,flags,data.len);
        try enc.write(data);
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



// https://www.rfc-editor.org/rfc/rfc9113.html#name-headers
pub fn encodeHeaders(self :Self, alloc :std.mem.Allocator, enc :std.io.AnyWriter,id :ID,header :hpack.Header,table :*hpack.Table,padding :?u8, priority :?Priority) !void  {
    const DynamicWriter = std.fifo.LinearFifo(u8,.Dynamic);
    var hpackCompressed :DynamicWriter = DynamicWriter.init(alloc);
    defer hpackCompressed.deinit();
    try hpack.encodeHeader(alloc,hpackCompressed.writer().any(),header,table,null);
    var slice = hpackCompressed.readableSlice(0);
    var flags = Flags.init();
    const optional_fields_len :usize= (if (padding) |p| 1 + p else 0) + (if (priority) |_| @as(usize,5) else 0);
    var len :usize = slice.len + optional_fields_len;
    if(padding) |_| {
        flags.set_padded();
    }
    if(priority) |_| {
        flags.set_priority();
    }
    if(len > self.peer_max_frame_size) {
        len = self.peer_max_frame_size;
    }
    else {
        flags.set_end_headers();
    }
    try self.encodeHeader(enc,id,H2FrameType.HEADDER,flags,len);
    if(padding) |p| {
        try enc.writeByte(p);
        len -= 1 + p;
    }
    if(priority) |p| {
        try enc.writeAll(&p.encode());
        len -= 5;
    }
    try enc.writeAll(slice[0..len]);
    slice = slice[len..];
    if(padding) |p| {
        try enc.writeByteNTimes(0, p);
    }
    while(slice.len > 0) {
        flags = Flags.init();
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
    }
}

const settings = @import("settings.zig");

pub fn encodeSettings(self: Self,enc :std.io.AnyWriter,ack :bool, definedSettings :?settings.DefinedSettings, additionalSettings :?[]settings.Setting) !void {
    var flags = Flags.init();
    if(ack) {
        flags.set_ack();
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

pub fn encodeGoaway(self :Self,enc :std.io.AnyWriter,last_stream_id :ID,error_code :u32,debug_data :?[]u8) !void {
    const len = 8 + if(debug_data) debug_data.len else 0;
    try self.encodeHeader(enc,CONNECTION,H2FrameType.GOAWAY,Flags.is_none(),len);
    try enc.writeInt(u32, @as(u32,last_stream_id),.Big);
    try enc.writeInt(u32, error_code,.Big);
    try enc.write(debug_data);
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
        rst_stream :u32,
        settings :?std.ArrayList(settings.Setting),
        push_promise :struct {
            promised_stream_id :ID,
            header :hpack.Header,
        },
        ping :u64,
        goaway :struct {
            last_stream_id :ID,
            error_code :u32,
            debug_data :hpack.U8Array,
        },
        window_update :u32,
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

fn readPadding(len :?u8, r :std.io.AnyReader) !void {
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
        H2FrameType.HEADDER => {
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
        },
        H2FrameType.PRIORITY => {
            if(header.stream_id == CONNECTION) {
                return error.InvalidStreamID0;
            }
        },
        H2FrameType.PUSH_PROMISE => {
            if(header.stream_id == CONNECTION) {
                return error.InvalidStreamID0;
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
            // nothing to do
        },
    }
}
 
fn decodeData(alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame)  !void {
    try typeIDCheck(H2FrameType.DATA,frame.header,null);
    var len = frame.*.header.length;
    try mayReadPadLen(&frame.payload.data.padding,&len,r,frame);
    frame.payload.data.data = try readBytes(len,alloc,r);
    try readPadding(frame.payload.data.padding,r);
}

fn decodeHeaders(self :Self,table :*hpack.Table, alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.HEADDER,frame.header,null);
    var len = frame.*.header.length;
    frame.payload = .{.headers = undefined};
    try mayReadPadLen(&frame.payload.headers.padding,&len,r,frame);
    try mayReadPriority(&len,&frame.payload.headers.priority,frame.header.flags,r);
    var headerCompressed = try readBytes(len,alloc,r);
    defer headerCompressed.deinit();
    try readPadding(frame.payload.headers.padding,r);
    if(!(frame.header.flags.is_end_headers())) {
        while(true) {
            const hdr = try self.decodeFrameHeader(r);
            try typeIDCheck(H2FrameType.CONTINUATION,hdr,frame.header.stream_id);
            const oldLen = headerCompressed.items.len;
            try headerCompressed.resize(oldLen + hdr.length);
            try r.readNoEof(headerCompressed.items[oldLen..]);
            if(hdr.flags.is_end_headers()) {
                break;
            }
        }
    }
    var stream =  std.io.fixedBufferStream(headerCompressed.items);
    frame.payload.headers.header = try hpack.decodeHeader(alloc,stream.reader().any(),table);
}

fn decodeSettings(alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.SETTINGS,frame.header,null);
    if(frame.header.length == 0) {
        frame.payload.settings = null;
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
    frame.payload.goaway.last_stream_id = try r.readInt(u32,.Big);
    frame.payload.goaway.error_code = try r.readInt(u32,.Big);
    try readBytes(&frame.payload.goaway.debug_data,frame.header.length - 8,alloc,r);
}

/// Decode one or more frames from the reader.
/// if frame is a HEADER frame and the END_HEADERS flag is not set, the function will read the continuation frames.
/// and decode the headers.
pub fn decodeFrames(self :Self, alloc :std.mem.Allocator, r :std.io.AnyReader,table :*hpack.Table) !Frame {
    const hdr :FrameHeader= try self.decodeFrameHeader(r);
    var frame = Frame{ .header = hdr, .payload = undefined };
    errdefer frame.deinit();
    switch(frame.header.typ) {
        .typ =>|t| switch(t) {
            H2FrameType.DATA => {
                try decodeData(alloc,r,&frame);
            },
            H2FrameType.HEADDER => {
                try self.decodeHeaders(table,alloc,r,&frame);
            },
            H2FrameType.CONTINUATION => {
                return error.InvalidContinuation;
            },
            H2FrameType.SETTINGS => {
                try decodeSettings(alloc,r,&frame);
            },
            else => {
                @panic("Not implemented");
            }
        },
        else => {
            frame.payload.opaque_data =  try readBytes(frame.header.length,alloc,r);
        }
    }
    return frame;
} 

pub fn init() Self {
    return Self{ };
}
