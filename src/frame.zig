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

const Flags = enum(u8) {
    ACK = 0x1,
    END_STREAM = 0x1,
    PADDED = 0x8,
    END_HEADERS = 0x4,
    PRIORITY = 0x20,
};

const Self = @This();

max_frame_size :u24 = 16384,

const FrameHeader = struct {
    const Self = FrameHeader;
    length: u24,
    typ: H2FrameType,
    flags: Flags,
    stream_id: ID,
};

fn encodeFrameHeader(frame :FrameHeader,enc :std.io.AnyWriter) anyerror!void{
    try enc.writeInt(u24, frame.length,.Big);
    try enc.writeByte(u8(frame.typ));
    try enc.writeByte(@as(u8,frame.flags));
    try enc.writeInt(u32, @as(u32,frame.stream_id),.Big);
}

fn decodeFrameHeader(enc :std.io.AnyReader) anyerror!FrameHeader {
    var hdr = FrameHeader{};
    try enc.readInt(u24, &hdr.length,.Big);
    hdr.typ = H2FrameType(enc.readByte());
    hdr.flags = enc.readByte();
    try enc.readInt(u32, &hdr.stream_id,.Big);
    return hdr;
}

const ID = u31;

const CONNECTION :ID = 0;

fn encodeHeader(self :Self, enc :std.io.AnyWriter, id :ID,typ :H2FrameType,flags :Flags,len :usize) !void {
    if(len > 0x00FFFFFF) {
        return error.TooLongData;
    }
    if(len > self.max_frame_size) {
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
    var flags = @as(Flags,0);
    if (endOfStream) {
        flags |= Flags.END_STREAM;
    }
    if (padding) |pad| {
        flags |= Flags.PADDED;
        var p :[256]u8 = {};
        try self.encodeHeader(enc,id,H2FrameType.DATA,flags,data.len + 1 + pad);
        p[0] = pad;
        try enc.write(p[0..1]);
        try enc.write(data);
        try enc.write(p[1..1+pad]);
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
pub fn encodeHeaders(self :Self, alloc :std.mem.Allocator, enc :std.io.AnyWriter,id :ID,header :hpack.Header,table :*hpack.Table,padding :?*u8, priority :?Priority) !void  {
    const DynamicWriter = std.fifo.LinearFifo(u8,.Dynamic);
    var hpackCompressed :DynamicWriter = DynamicWriter.init(alloc);
    try hpack.encodeHeader(alloc,hpackCompressed.writer().any(),header,table,null);
    var slice = hpackCompressed.readableSlice(0);
    var flags = @as(Flags,0);
    var len :usize = slice.len + if (padding) |p| 1 + p else 0 + if (priority) 5 else 0;
    if(padding) {
        flags |= Flags.PADDED;
    }
    if(priority) {
        flags |= Flags.PRIORITY;
    }
    if(len >= self.max_frame_size) {
        
    }
    else {
        flags |= Flags.END_HEADERS;
    }
    try encodeHeader(enc,id,H2FrameType.HEADDER,flags,len);    
}
