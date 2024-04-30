
const std = @import("std");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");

pub fn main() !void {
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
    try hpack.encodeHeader(stream.writer().any(), header);
    const reader = stream.reader().any();
    const decodedHeader = try hpack.decodeHeader(alloc, reader);
    try std.testing.expect(hpack.equalHeader(header,decodedHeader));
}
