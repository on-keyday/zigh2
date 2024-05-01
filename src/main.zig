
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
    var h2client  = try client.SignleThreadClient.init(alloc,.{.enablePush = false},null);
    _ = try h2client.createStream();
    //var netStream = try std.net.tcpConnectToHost(alloc,"shiguredo.jp",443);
    //var bundle =  std.crypto.Certificate.Bundle{};
    //try bundle.addCertsFromFilePath(alloc,std.fs.cwd(),"cacert.pem");
    //var tlsClient = try tls.Client.init(netStream,bundle,"shiguredo.jp");
    //stream.sendData();
}
