
const std = @import("std");
const hpack = @import("hpack.zig");
const frame = @import("frame.zig");

const settings = @import("settings.zig");
const Flags = @import("Flags.zig");
const connection = @import("connection.zig");
const TLSClient = @import("tls/Client.zig");

const std_options :std.Options = .{
    .log_level = std.log.Level.debug,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var args =  try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    var host :?[]const u8 = null;
    var cert :?[]const u8 = null; 
    var procName :?[]const u8 = null;
    while(args.next()) |arg| {
        if(procName == null) {
            procName = arg;
        }
        else if(host==null) {
            host = arg;
        }
        else if(cert==null) {
            cert = arg;
        }
    }
    if(host == null) {
        std.debug.print("Usage: {?s} host [cert]\n",.{procName});
        return;
    }
    if(cert == null) {
        cert = "cacert.pem";
    }
    var h2client  = try connection.SignleThreadClient.init(alloc,true,.{.enablePush = false},null);
    var stream = try h2client.createStream();
    try stream.deinit();
    var hdr = hpack.Header.init(alloc);
    try hdr.add(":scheme","https");
    try hdr.add(":method","GET");
    try hdr.add(":path","/");
    try hdr.add(":authority",host.?);
    try hdr.add("user-agent","ZigH2Client/0.1.0");
    try stream.sendHeader(alloc,hdr,true);    
    const request = h2client.getSendBuffer();
    defer request.deinit();
    var netStream = try std.net.tcpConnectToHost(alloc,host.?,443);
    var bundle =  std.crypto.Certificate.Bundle{};
    try bundle.addCertsFromFilePath(alloc,std.fs.cwd(),cert.?);
    const alpn :[3]u8 = "\x02h2".*;
    var tlsClient = try TLSClient.init(netStream,bundle,host.?,alpn);
    try tlsClient.writeAll(&netStream,request.readableSlice(0));
    var peerHeader :?hpack.Header = null;
    defer if(peerHeader) |*d| d.deinit();
    const out = std.io.getStdOut();
    while(true) {
        const request2 = h2client.getSendBuffer();
        defer request2.deinit();
        if(request2.readableLength() > 0) {
            tlsClient.writeAll(&netStream,request2.readableSlice(0)) catch |e| {
                std.log.debug("writeAll error: {}\n",.{e});
                break;
            };
            if(h2client.goawayCode) |_| {
                break;
            }
        }
        var buf :[4096]u8 = undefined;
        const len = try tlsClient.read(&netStream,buf[0..]);
        std.log.debug("read: {} data:{any}\n data_str: {s}\n",.{len,buf[0..len],buf[0..len]});
        
        try h2client.handlePeer(alloc, buf[0..len]);
        if(peerHeader == null) {
            if(try stream.readHeader()) |header| {
                peerHeader = header.header;
                const stdout = std.io.getStdOut().writer();
                try hpack.printHeader(stdout,peerHeader.?);
            }
            else {
                continue;
            }
        }
        while(true) {
            const len2 = stream.recvData(buf[0..]);
            if(len2 == null) {
                try h2client.sendGoaway(0,stream.id,null);                
                break;
            }
            if(len2.? == 0) {
                break;
            }
            try out.writeAll(buf[0..len2.?]);
        }
    }
}
