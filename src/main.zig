
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
    var hdr = hpack.Header.init(alloc);
    try hdr.add(":scheme","https");
    try hdr.add(":method","GET");
    try hdr.add(":path","/");
    try hdr.add(":authority","shiguredo.jp");
    try hdr.add("user-agent","ZigH2Client/0.1.0");
    try stream.sendHeader(alloc,hdr,true);    
    const request = h2client.getSendBuffer();
    var netStream = try std.net.tcpConnectToHost(alloc,"shiguredo.jp",443);
    var bundle =  std.crypto.Certificate.Bundle{};
    try bundle.addCertsFromFilePath(alloc,std.fs.cwd(),"cacert.pem");
    var tlsClient = try tls.Client.init(netStream,bundle,"shiguredo.jp");
    try tlsClient.writeAll(&netStream,request.readableSlice(0));
    while(true) {
        var buf :[4096]u8 = undefined;
        const len = try tlsClient.read(&netStream,buf[0..]);
        try h2client.handlePeer(alloc, buf[0..len]);
        const peerHeader = try stream.readHeader();
        _ = peerHeader;
    }
}
