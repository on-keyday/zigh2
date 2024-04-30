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

const initial_max_frame_size = 16384;

peer_max_frame_size :u24 = initial_max_frame_size,
local_max_frame_size :u24 = initial_max_frame_size,


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
    try enc.writeInt(u24, frame.length,.Big);
    try enc.writeByte(@bitCast(frame.typ));
    try enc.writeByte(@as(u8,frame.flags.value));
    try enc.writeInt(u32, @as(u32,frame.stream_id),.Big);
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
    hdr.typ.unknown_type = try enc.readByte();
    if(intToType(hdr.typ.unknown_type)) |typ| {
        hdr.typ.typ = typ;
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
        .typ = typ,
        .flags = flags,
        .stream_id = id,
    };
    try encodeFrameHeader(hdr,enc);
}

//https://www.rfc-editor.org/rfc/rfc9113.html#name-data
pub fn encodeData(self :Self,enc :std.io.AnyWriter,id :ID,data :[]u8, endOfStream :bool, padding:?u8) !void {
    var flags = Flags.NONE;
    if (endOfStream) {
        flags |= Flags.END_STREAM;
    }
    if (padding) |pad| {
        flags |= Flags.PADDED;
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
        buf[0] |= (self.stream_dependency >> 24) & 0x7F;
        buf[1] = (self.stream_dependency >> 16) & 0xFF;
        buf[2] = (self.stream_dependency >> 8) & 0xFF;
        buf[3] = self.stream_dependency & 0xFF;
        buf[4] = self.weight;
        return buf;
    }
};



// https://www.rfc-editor.org/rfc/rfc9113.html#name-headers
pub fn encodeHeaders(self :Self, alloc :std.mem.Allocator, enc :std.io.AnyWriter,id :ID,header :hpack.Header,table :*hpack.Table,padding :?u8, priority :?Priority) !void  {
    const DynamicWriter = std.fifo.LinearFifo(u8,.Dynamic);
    var hpackCompressed :DynamicWriter = DynamicWriter.init(alloc);
    try hpack.encodeHeader(alloc,hpackCompressed.writer().any(),header,table,null);
    var slice = hpackCompressed.readableSlice(0);
    var flags = Flags.init();
    const optional_fields_len = if (padding) |p| 1 + p else 0 + if (priority) 5 else 0;
    var len :usize = slice.len + optional_fields_len;
    if(padding) {
        flags.set_padded();
    }
    if(priority) {
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
        try enc.write(p.encode());
        len -= 5;
    }
    try enc.write(slice[0..len]);
    slice = slice[len..];
    if(padding) {
        try enc.writeByteNTimes(0, padding);
    }
    while(slice.len > 0) {
        flags = flags.init();
        if(slice.len > self.peer_max_frame_size) {
            len = self.peer_max_frame_size;
        }
        else {
            flags.set_end_headers();
            len = slice.len;
        }
        try self.encodeHeader(enc,id,H2FrameType.CONTINUATION,flags,len);
        try enc.write(slice[0..len]);
        slice = slice[len..];
    }
}

const Setting = struct {
    id :u16,
    value :u32,
};

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
        settings :[]Setting,
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

fn readBytes(data :*hpack.U8Array, len :u24,alloc :std.mem.Allocator, r :std.io.AnyReader) !void {
    data.* = hpack.U8Array.init(alloc);
    try data.*.resize(len);
    try r.readNoEof(data.*.items);
}

fn readPriority( r :std.io.AnyReader) !Priority {
    const b = try r.readBytesNoEof(5);
    const data = Priority{};
    data.exclusive = b[0] & 0x80 != 0;
    data.stream_dependency = (u32(b[0] & 0x7F) << 24) | (u32(b[1]) << 16) | (u32(b[2]) << 8) | u32(b[3]);
    data.weight = b[4];
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
        else => {
            @compileError("Not implemented");
        },
    }
}
 
fn decodeData(alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame)  !void {
    try typeIDCheck(H2FrameType.DATA,frame.header,null);
    var len = frame.*.header.length;
    try mayReadPadLen(&frame.payload.data.padding,&len,r,frame);
    try readBytes(&frame.payload.data.data,len,alloc,r);
    try readPadding(frame.payload.data.padding,r);
}

pub fn decodeHeaders(self :Self, alloc :std.mem.Allocator, r :std.io.AnyReader,frame :*Frame) !void {
    try typeIDCheck(H2FrameType.HEADDER,frame.header,null);
    var len = frame.*.header.length;
    try mayReadPadLen(&frame.payload.data.padding,&len,r,frame);
    try mayReadPriority(&len,&frame.payload.headers.priority,frame.header.flags,r);
    var headerCompressed :hpack.U8Array = undefined;
    try readBytes(&headerCompressed,len,alloc,r);
    try readPadding(frame.payload.headers.padding,r);
    if(!(frame.*.header.flags & Flags.END_HEADERS)) {
        while(true) {
            const hdr = try self.decodeFrameHeader(r);
            try typeIDCheck(H2FrameType.CONTINUATION,hdr,frame.header.id);
            const oldLen = headerCompressed.len;
            headerCompressed.resize(oldLen + hdr.length);
            try r.readNoEof(headerCompressed.items[oldLen..]);
            if(hdr.flags & Flags.END_HEADERS) {
                break;
            }
        }
    }
}

pub fn decodeFrames(self :Self, alloc :std.mem.Allocator, r :std.io.AnyReader) !Frame {
    const hdr :FrameHeader= try self.decodeFrameHeader(r);
    var frame = Frame{ .header = hdr, .payload = undefined };
    errdefer frame.deinit();
    switch(frame.header.typ) {
        .typ =>|t| switch(t) {
            H2FrameType.DATA => {
                try decodeData(alloc,r,&frame);
            },
            else => {
                @panic("Not implemented");
            }
        },
        else => {
            try readBytes(&frame.payload.opaque_data,frame.header.length,alloc,r);
        }
    }
    return frame;
} 

pub fn init() Self {
    return Self{
        .peer_max_frame_size = initial_max_frame_size,
        .local_max_frame_size = initial_max_frame_size,
    };
}
