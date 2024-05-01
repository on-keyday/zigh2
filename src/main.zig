
const std = @import("std");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");

const settings = @import("settings.zig");
const Flags = @import("Flags.zig");
const client = @import("client.zig");
const tls = std.crypto.tls;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var h2client  = try client.SignleThreadClient.initClient(alloc,.{.enablePush = false},null);
    var stream = try h2client.createStream();
    try stream.deinit();
    //var netStream = try std.net.tcpConnectToHost(alloc,"shiguredo.jp",443);
    //var bundle =  std.crypto.Certificate.Bundle{};
    //try bundle.addCertsFromFilePath(alloc,std.fs.cwd(),"cacert.pem");
    //var tlsClient = try tls.Client.init(netStream,bundle,"shiguredo.jp");
    const hdr = hpack.Header.init(alloc);
    hdr.add(":scheme","https");
    hdr.add(":method","GET");
    hdr.add(":path","/");
    hdr.add(":authority","shiguredo.jp");
    try stream.sendHeader(alloc,hdr,true);    
}
