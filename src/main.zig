
const std = @import("std");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");

const settings = @import("settings.zig");

pub fn main() !void {
   var gpa = std.heap.GeneralPurposeAllocator(.{}){};
   const alloc = gpa.allocator();
   defer _ = gpa.deinit();
   var buf: [1024]u8 = undefined;
   var s =  std.io.fixedBufferStream(buf[0..]);
   const framer = frame.init();
   try framer.encodeSettings(s.writer().any(),false,settings.DefinedSettings{.enablePush = false},null);
   var hdr =  hpack.Header.init(alloc);
   defer hdr.deinit();
   for(0..1) |_| {
      try hpack.addHeader(alloc, &hdr, "x-test", "test");
      try hpack.addHeader(alloc, &hdr, "content-type", "text/html");
      try hpack.addHeader(alloc, &hdr, "content-length", "0");
      try hpack.addHeader(alloc, &hdr, "date", "Mon, 21 Oct 2013 20:13:21 GMT");
   }
   var encoder_table = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
   defer encoder_table.deinit();
   try framer.encodeHeaders(alloc, s.writer().any(),1,false,hdr,&encoder_table,null,null);
   try framer.encodeData(s.writer().any(),1,"Hello World from Zig!",true,null);
   s.reset();
   var decoder_table = hpack.Table.init(alloc,hpack.DEFAULT_TABLE_SIZE);
   defer decoder_table.deinit();
   var d = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer d.deinit();
   var h = try framer.decodeFrames(alloc,s.reader().any(),&decoder_table);
   defer h.deinit();
   
}
