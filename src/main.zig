
const std = @import("std");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");



pub fn main() !void {
   var gpa = std.heap.GeneralPurposeAllocator(.{}){};
   const allocator = gpa.allocator();
   const buf: [1024]u8 = undefined;
   var s =  std.io.fixedBufferStream(buf[0..]);
   const framer = frame.init();
   var d = try framer.decodeFrames(allocator,s.reader().any());
   defer d.deinit();
}
