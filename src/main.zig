
const std = @import("std");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");

fn printHeader(header :hpack.Header) !void {
    var iter = header.iterator();
    const stdout = std.io.getStdOut().writer();
    while(iter.next()) |field| {
        const key :hpack.U8Array = field.key_ptr.*;
        for(field.value_ptr.*.items) |v| {
            const value :hpack.U8Array = v;
            try stdout.print("{s}: {s}\n", .{key.items, value.items});
        }
    }

}

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
    var reader = std.io.fixedBufferStream(stream.getWritten());
    const decodedHeader = try hpack.decodeHeader(alloc, reader.reader().any());
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Header\n",.{});
    try printHeader(header);
    try stdout.print("Decoded Header\n",.{});
    try printHeader(decodedHeader);
    try std.testing.expect(hpack.equalHeader(header,decodedHeader));
}
