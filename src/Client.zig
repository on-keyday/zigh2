
const preface  = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const Framer = @import("frame.zig");
const hpack = @import("hpack.zig");

const std = @import("std");
const Stream = @import("stream.zig");

const tls = std.crypto.tls;


framer :Framer,
encodeTable :hpack.Table,
decodeTable :hpack.Table,
recvBuffer :Framer.DynamicStream,   
sendBuffer :Framer.DynamicStream,
prefaceRecved :bool = false,
nextID :Framer.ID,

const Self = @This();

fn sendPreface(self:*Self) !void {
    try self.sendBuffer.writer().any().writeAll(preface);
}

pub fn init(alloc :std.mem.Allocator) !Self {
    var self: Self = undefined;
    self.framer = Framer.init();
    self.encodeTable = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
    self.decodeTable = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
    self.recvBuffer = Framer.DynamicStream.init(alloc);
    self.sendBuffer = Framer.DynamicStream.init(alloc);
    try self.sendPreface();
    self.nextID = Framer.ClientInitialID;
    return self;
}

pub fn createStream(self :*Self) !Stream {
    const id = self.nextID;
    self.nextID = Framer.nextID(id);
    return Stream.init(id, self);
}