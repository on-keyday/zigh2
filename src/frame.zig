const std = @import("std");
const H2FrameType = enum {
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

const FrameHeader = struct {
    const Self = FrameHeader;
    length: u24,
    typ: H2FrameType,
    flags: u8,
    stream_id: u32,
};

fn encode(frame :FrameHeader,enc :std.io.AnyWriter) anyerror!void{
    try enc.writeInt(u24, frame.length,.Big);
    try enc.writeByte(u8(frame.typ));
    try enc.writeByte(frame.flags);
    try enc.writeInt(u32, frame.stream_id,.Big);
}

fn decode(enc :std.io.AnyReader) anyerror!FrameHeader {
    var hdr = FrameHeader{};
    try enc.readInt(u24, &hdr.length,.Big);
    hdr.typ = H2FrameType(enc.readByte());
    hdr.flags = enc.readByte();
    try enc.readInt(u32, &hdr.stream_id,.Big);
    return hdr;
}

